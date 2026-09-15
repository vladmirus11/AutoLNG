unit uAutoCorrect;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.Generics.Collections, System.IOUtils, uLayoutCore, uDictionary;

type
  TAppLanguage = (langUnknown, langRu, langEn);

  // В Winapi.Windows Delphi XE2 эта структура не объявлена (она появилась
  // в юните позже), поэтому описываем её сами - layout соответствует
  // официальной структуре WinAPI KBDLLHOOKSTRUCT.
  PKBDLLHOOKSTRUCT = ^TKBDLLHOOKSTRUCT;
  TKBDLLHOOKSTRUCT = record
    vkCode: DWORD;
    scanCode: DWORD;
    flags: DWORD;
    time: DWORD;
    dwExtraInfo: ULONG_PTR;
  end;

  TKeyEvent = record
    vkCode: DWORD;
    scanCode: DWORD;
    KeyState: TKeyboardState256;
  end;

  TLastCorrection = record
    Active: Boolean;
    OldWord, NewWord: string;
    TickCount: Cardinal;
  end;

  TLastLineInfo = record
    Words: TStringList;           // Список слов последней строки
    BufferCopies: array of TArray<TKeyEvent>; // Массив буферов для каждого слова
    StartTick: Cardinal;
  end;

  TAutoCorrectEngine = class
  private
    FHookHandle: HHOOK;
    FHklRu, FHklEn: HKL;
    FDicRu, FDicEn: TWordDictionary;

    FBuffer: TList<TKeyEvent>;
    FTypedWord: string;           // слово так, как оно реально печатается
    FTypedWordLang: TAppLanguage; // в какой раскладке оно печаталось

    FShiftDown, FCtrlDown, FAltDown, FCapsOn: Boolean;
    FLastForegroundWnd: HWND;

    FLastCorrection: TLastCorrection;
    FLastLine: TLastLineInfo;

    FEnabled: Boolean;
    FExcludedClasses: TStringList; // классы окон, где коррекция выключена

    FLogPath: string;
    FLogEnabled: Boolean;
    
    // Для отслеживания одиночного/двойного нажатия правого Ctrl
    FRightCtrlPressTime: Cardinal;
    FRightCtrlPressCount: Integer;

    procedure LogMsg(const S: string);

    procedure ResetWordBuffer;
    procedure ResetLastLine;
    function IsModifierKey(vkCode: DWORD): Boolean;
    function IsBoundaryKey(vkCode: DWORD): Boolean;
    function BuildKeyState: TKeyboardState256;
    function CurrentForegroundHkl: HKL;
    function HklLangId(H: HKL): Word;
    function IsExcludedWindow: Boolean;
    function IsPasswordField: Boolean;

    procedure ProcessWordBoundary;
    procedure PerformCorrection(const OldWord, NewWord: string; NewLang: TAppLanguage);
    procedure SwitchLayoutForForeground(Lang: TAppLanguage);

    procedure TryRevertLastCorrection;
    
    // Методы для обработки правого Ctrl
    procedure HandleRightCtrlPress;
    procedure ToggleLastWord;
    procedure ToggleLastLine;
  public
    constructor Create(const DictRuPath, DictEnPath: string);
    destructor Destroy; override;

    procedure InstallHook;
    procedure RemoveHook;

    // Вызывается из хук-процедуры (см. LowLevelKeyboardProc)
    procedure HandleKeyDown(vkCode, scanCode: DWORD);
    procedure HandleKeyUp(vkCode: DWORD);

    property Enabled: Boolean read FEnabled write FEnabled;
    property ExcludedClasses: TStringList read FExcludedClasses;
  end;

var
  GEngine: TAutoCorrectEngine;

implementation

const
  // Уникальная метка, которой мы помечаем СВОИ собственные искусственные
  // нажатия клавиш (Backspace/Unicode-текст), чтобы хук их отличал от
  // настоящих нажатий пользователя и не обрабатывал их повторно.
  // Без этой метки программа зациклится сама на себе.
  INJECTED_SIGNATURE: ULONG_PTR = $ABCD0001;

  UNDO_TIMEOUT_MS = 3000; // сколько времени после коррекции действует Ctrl+Z

  // Стандартные идентификаторы языка Windows (младшее слово HKL).
  // Сравниваем именно с этими константами, а не с FHklRu/FHklEn -
  // это надёжнее: LoadKeyboardLayout иногда возвращает HKL, у которого
  // старшее слово (вариант раскладки/устройство) отличается от того,
  // что вернёт GetKeyboardLayout для реального активного окна, а нам
  // важен только язык.
  LANGID_RUSSIAN    = $0419;
  LANGID_ENGLISH_US = $0409;

{ ---------- Низкоуровневые функции отправки "искусственных" нажатий ---------- }

procedure SendBackspaces(Count: Integer);
var
  Inputs: array of TInput;
  I: Integer;
begin
  if Count <= 0 then Exit;
  SetLength(Inputs, Count * 2);
  for I := 0 to Count - 1 do
  begin
    FillChar(Inputs[I * 2], SizeOf(TInput), 0);
    Inputs[I * 2].Itype := INPUT_KEYBOARD;
    Inputs[I * 2].ki.wVk := VK_BACK;
    Inputs[I * 2].ki.dwExtraInfo := INJECTED_SIGNATURE;

    Inputs[I * 2 + 1] := Inputs[I * 2];
    Inputs[I * 2 + 1].ki.dwFlags := KEYEVENTF_KEYUP;
  end;
  SendInput(Length(Inputs), Inputs[0], SizeOf(TInput));
end;

procedure SendUnicodeText(const S: string);
var
  Inputs: array of TInput;
  I: Integer;
begin
  if S = '' then Exit;
  SetLength(Inputs, Length(S) * 2);
  for I := 1 to Length(S) do
  begin
    FillChar(Inputs[(I - 1) * 2], SizeOf(TInput), 0);
    Inputs[(I - 1) * 2].Itype := INPUT_KEYBOARD;
    Inputs[(I - 1) * 2].ki.wScan := Word(S[I]);
    Inputs[(I - 1) * 2].ki.dwFlags := KEYEVENTF_UNICODE;
    Inputs[(I - 1) * 2].ki.dwExtraInfo := INJECTED_SIGNATURE;

    Inputs[(I - 1) * 2 + 1] := Inputs[(I - 1) * 2];
    Inputs[(I - 1) * 2 + 1].ki.dwFlags := KEYEVENTF_UNICODE or KEYEVENTF_KEYUP;
  end;
  SendInput(Length(Inputs), Inputs[0], SizeOf(TInput));
end;

{ ---------- Хук-процедура (должна быть простой функцией, не методом) ---------- }

function LowLevelKeyboardProc(nCode: Integer; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  Info: PKBDLLHOOKSTRUCT;
begin
  if (nCode = HC_ACTION) and Assigned(GEngine) then
  begin
    Info := PKBDLLHOOKSTRUCT(lParam);
    // Пропускаем события, которые мы сами сгенерировали через SendInput -
    // иначе программа будет реагировать на собственные исправления.
    if Info^.dwExtraInfo <> INJECTED_SIGNATURE then
    begin
      if GEngine.Enabled then
      begin
        if (wParam = WM_KEYDOWN) or (wParam = WM_SYSKEYDOWN) then
          GEngine.HandleKeyDown(Info^.vkCode, Info^.scanCode)
        else if (wParam = WM_KEYUP) or (wParam = WM_SYSKEYUP) then
          GEngine.HandleKeyUp(Info^.vkCode);
      end;
    end;
  end;
  // Мы НИКОГДА не "проглатываем" клавиши - только наблюдаем.
  // Коррекция делается постфактум через Backspace + новый текст.
  // Это гораздо надёжнее, чем пытаться подменять символы на лету.
  Result := CallNextHookEx(0, nCode, wParam, lParam);
end;

{ ---------- TAutoCorrectEngine ---------- }

constructor TAutoCorrectEngine.Create(const DictRuPath, DictEnPath: string);
begin
  inherited Create;

  FHklRu := LoadLayoutHandle(KLID_RUSSIAN);
  FHklEn := LoadLayoutHandle(KLID_ENGLISH);

  FDicRu := TWordDictionary.Create;
  FDicRu.LoadFromFile(DictRuPath);

  FDicEn := TWordDictionary.Create;
  FDicEn.LoadFromFile(DictEnPath);

  FBuffer := TList<TKeyEvent>.Create;

  FExcludedClasses := TStringList.Create;
  FExcludedClasses.CaseSensitive := False;
  // Разумные значения по умолчанию: консоли, терминалы, IDE и т.п.,
  // где авто-исправление раскладки почти всегда мешает.
  FExcludedClasses.Add('ConsoleWindowClass');
  FExcludedClasses.Add('CASCADIA_HOSTING_WINDOW_CLASS'); // Windows Terminal
  FExcludedClasses.Add('PuTTY');
  FExcludedClasses.Add('mintty');

  FEnabled := True;
  ResetWordBuffer;

  // Инициализация переменных для правого Ctrl
  FRightCtrlPressTime := 0;
  FRightCtrlPressCount := 0;
  FLastLine.Words := TStringList.Create;
  FLastLine.StartTick := 0;
  SetLength(FLastLine.BufferCopies, 0);

  FLogPath := ExtractFilePath(ParamStr(0)) + 'debug.log';
  FLogEnabled := True; // поставьте False, когда всё заработает - это временная диагностика
  LogMsg(Format('=== Движок запущен. Словарь RU: %d слов, словарь EN: %d слов ===',
    [FDicRu.Count, FDicEn.Count]));
end;

destructor TAutoCorrectEngine.Destroy;
begin
  RemoveHook;
  FBuffer.Free;
  FDicRu.Free;
  FDicEn.Free;
  FExcludedClasses.Free;
  FLastLine.Words.Free;
  inherited;
end;

procedure TAutoCorrectEngine.InstallHook;
begin
  if FHookHandle = 0 then
    FHookHandle := SetWindowsHookEx(WH_KEYBOARD_LL, @LowLevelKeyboardProc, 0, 0);
  if FHookHandle = 0 then
    RaiseLastOSError;
end;

procedure TAutoCorrectEngine.RemoveHook;
begin
  if FHookHandle <> 0 then
  begin
    UnhookWindowsHookEx(FHookHandle);
    FHookHandle := 0;
  end;
end;

procedure TAutoCorrectEngine.ResetWordBuffer;
begin
  FBuffer.Clear;
  FTypedWord := '';
  FTypedWordLang := langUnknown;
end;

procedure TAutoCorrectEngine.ResetLastLine;
begin
  FLastLine.Words.Clear;
  SetLength(FLastLine.BufferCopies, 0);
  FLastLine.StartTick := 0;
end;

procedure TAutoCorrectEngine.LogMsg(const S: string);
var
  Line: string;
begin
  if not FLogEnabled then Exit;
  Line := FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + S + sLineBreak;
  try
    if not TFile.Exists(FLogPath) then
      TFile.WriteAllText(FLogPath, Line, TEncoding.UTF8)
    else
      TFile.AppendAllText(FLogPath, Line, TEncoding.UTF8);
  except
    // Диагностика не должна ронять программу, если, например, лог
    // занят другим просмотрщиком - просто молча пропускаем запись.
  end;
end;

function TAutoCorrectEngine.IsModifierKey(vkCode: DWORD): Boolean;
begin
  Result := vkCode in [VK_SHIFT, VK_LSHIFT, VK_RSHIFT,
                       VK_CONTROL, VK_LCONTROL, VK_RCONTROL,
                       VK_MENU, VK_LMENU, VK_RMENU,
                       VK_CAPITAL, VK_LWIN, VK_RWIN];
end;

function TAutoCorrectEngine.IsBoundaryKey(vkCode: DWORD): Boolean;
begin
  Result := vkCode in [VK_SPACE, VK_RETURN, VK_TAB, VK_ESCAPE,
                       VK_OEM_PERIOD, VK_OEM_COMMA,
                       VK_OEM_1, VK_OEM_2, VK_OEM_3, VK_OEM_4,
                       VK_OEM_5, VK_OEM_6, VK_OEM_7,
                       VK_OEM_MINUS, VK_OEM_PLUS];
end;

function TAutoCorrectEngine.BuildKeyState: TKeyboardState256;
begin
  FillChar(Result, SizeOf(Result), 0);
  if FShiftDown then
  begin
    Result[VK_SHIFT] := $80;
    Result[VK_LSHIFT] := $80;
  end;
  if FCapsOn then
    Result[VK_CAPITAL] := $01;
  // Ctrl/Alt намеренно НЕ прокидываем в KeyState: если они зажаты,
  // мы вообще не добавляем клавишу в буфер слова (см. HandleKeyDown) -
  // это почти всегда горячая клавиша, а не набор текста.
end;

function TAutoCorrectEngine.CurrentForegroundHkl: HKL;
var
  Wnd: HWND;
  ThreadId: DWORD;
begin
  Wnd := GetForegroundWindow;
  if Wnd = 0 then
    Exit(FHklEn);
  ThreadId := GetWindowThreadProcessId(Wnd, nil);
  Result := GetKeyboardLayout(ThreadId);
end;

function TAutoCorrectEngine.HklLangId(H: HKL): Word;
begin
  // У HKL младшее слово - это идентификатор ЯЗЫКА (0x0419 - русский,
  // 0x0409 - английский США), а старшее слово - идентификатор конкретного
  // варианта раскладки/устройства. Он может отличаться у раскладки,
  // которую мы сами загрузили через LoadKeyboardLayout, и у раскладки,
  // которую возвращает GetKeyboardLayout для реально активного окна,
  // даже если язык один и тот же. Поэтому сравнивать HKL нужно только
  // по языку, а не целиком - иначе одно из направлений (например,
  // "набрал английское слово при активной русской раскладке") никогда
  // не будет распознано.
  Result := Word(NativeUInt(H) and $FFFF);
end;

function TAutoCorrectEngine.IsExcludedWindow: Boolean;
var
  Wnd: HWND;
  ClassBuf: array[0..255] of Char;
begin
  Result := False;
  Wnd := GetForegroundWindow;
  if Wnd = 0 then Exit;
  if GetClassName(Wnd, ClassBuf, Length(ClassBuf)) > 0 then
    Result := FExcludedClasses.IndexOf(ClassBuf) >= 0;
end;

function TAutoCorrectEngine.IsPasswordField: Boolean;
var
  Wnd: HWND;
  GUI: TGUIThreadInfo;
  Style: LONG_PTR;
begin
  Result := False;
  GUI.cbSize := SizeOf(GUI);
  if not GetGUIThreadInfo(0, GUI) then Exit;
  Wnd := GUI.hwndFocus;
  if Wnd = 0 then Exit;
  Style := GetWindowLongPtr(Wnd, GWL_STYLE);
  // ES_PASSWORD = $0020 для стандартных Edit-контролов
  Result := (Style and $0020) <> 0;
end;

procedure TAutoCorrectEngine.HandleKeyDown(vkCode, scanCode: DWORD);
var
  Event: TKeyEvent;
  Ch: WideChar;
  ActiveHkl: HKL;
  Wnd: HWND;
begin
  // Если сменилось окно/фокус с момента последнего события - буфер слова
  // и последняя строка уже не имеют смысла (пользователь кликнул в другое место).
  Wnd := GetForegroundWindow;
  if Wnd <> FLastForegroundWnd then
  begin
    ResetWordBuffer;
    ResetLastLine;
    FLastForegroundWnd := Wnd;
  end;

  // Отслеживаем состояние модификаторов сами, а не через GetKeyboardState -
  // внутри низкоуровневого хука GetKeyboardState не гарантированно
  // актуален (обновляется только при разборе очереди сообщений потока).
  case vkCode of
    VK_SHIFT, VK_LSHIFT, VK_RSHIFT: FShiftDown := True;
    VK_CONTROL, VK_LCONTROL, VK_RCONTROL: FCtrlDown := True;
    VK_MENU, VK_LMENU, VK_RMENU: FAltDown := True;
    VK_CAPITAL: FCapsOn := not FCapsOn;
  end;

  if IsModifierKey(vkCode) then
    Exit; // модификаторы сами по себе не входят в слово

  // Ctrl+Z сразу после нашей коррекции - откатываем её.
  if FCtrlDown and (vkCode = Ord('Z')) then
  begin
    TryRevertLastCorrection;
    Exit;
  end;

  if FCtrlDown or FAltDown then
  begin
    // Это горячая клавиша (Ctrl+C, Alt+Tab и т.д.), а не набор текста.
    ResetWordBuffer;
    Exit;
  end;

  if vkCode = VK_BACK then
  begin
    // Пользователь сам стирает - синхронизируем буфер, а не "чиним" его.
    if FBuffer.Count > 0 then
      FBuffer.Delete(FBuffer.Count - 1);
    if FTypedWord <> '' then
      Delete(FTypedWord, Length(FTypedWord), 1);
    Exit;
  end;

  if IsBoundaryKey(vkCode) then
  begin
    ProcessWordBoundary;
    ResetWordBuffer;
    // Если нажат Enter - это граница строки, сбрасываем последнюю строку
    if vkCode = VK_RETURN then
      ResetLastLine;
    Exit;
  end;

  // Обычная символьная клавиша - добавляем в буфер.
  Event.vkCode := vkCode;
  Event.scanCode := scanCode;
  Event.KeyState := BuildKeyState;
  FBuffer.Add(Event);

  // Параллельно вычисляем, что реально появилось на экране, используя
  // раскладку, активную в потоке окна, которое сейчас в фокусе.
  ActiveHkl := CurrentForegroundHkl;
  if KeyToChar(vkCode, scanCode, Event.KeyState, ActiveHkl, Ch) then
  begin
    FTypedWord := FTypedWord + Ch;
    if HklLangId(ActiveHkl) = LANGID_RUSSIAN then FTypedWordLang := langRu
    else if HklLangId(ActiveHkl) = LANGID_ENGLISH_US then FTypedWordLang := langEn
    else FTypedWordLang := langUnknown;
  end
  else
  begin
    // Клавиша не дала однозначного символа (например, мёртвая клавиша) -
    // безопаснее сбросить буфер слова, чем гадать.
    LogMsg(Format('KeyToChar не дал символа для vk=%d активная_hkl_langid=%.4x - сброс буфера',
      [vkCode, HklLangId(ActiveHkl)]));
    ResetWordBuffer;
  end;
end;

procedure TAutoCorrectEngine.HandleKeyUp(vkCode: DWORD);
begin
  case vkCode of
    VK_SHIFT, VK_LSHIFT, VK_RSHIFT: FShiftDown := False;
    VK_CONTROL, VK_LCONTROL, VK_RCONTROL: FCtrlDown := False;
    VK_MENU, VK_LMENU, VK_RMENU: FAltDown := False;
  end;

  // Обработка нажатия правого Ctrl (на отпускание, чтобы не было ложных срабатываний)
  if vkCode = VK_RCONTROL then
    HandleRightCtrlPress;
end;

function ContainsOnlyLetters(const S: string): Boolean;
var
  C: Char;
begin
  // ВАЖНО: нельзя использовать CharInSet с диапазонами типа 'а'..'я' -
  // TSysCharSet - это набор из 256 значений (AnsiChar), кириллица туда
  // просто не помещается (коды букв выше 255), и проверка всегда была
  // бы False для любого русского слова. Сравниваем ординалы WideChar
  // напрямую.
  Result := S <> '';
  for C in S do
  begin
    if not (
      ((C >= 'a') and (C <= 'z')) or
      ((C >= 'A') and (C <= 'Z')) or
      ((C >= 'а') and (C <= 'я')) or
      ((C >= 'А') and (C <= 'Я')) or
      (C = 'ё') or (C = 'Ё')
    ) then
      Exit(False);
  end;
end;

procedure TAutoCorrectEngine.ProcessWordBoundary;
var
  EnCandidate, RuCandidate, AltWord: string;
  Ch: WideChar;
  I: Integer;
  ActiveMatch, AltMatch: Boolean;
  NewLang: TAppLanguage;
begin
  if (FBuffer.Count < 2) or (FTypedWord = '') then
  begin
    LogMsg(Format('boundary: пропуск (buffer.count=%d typedWord="%s")', [FBuffer.Count, FTypedWord]));
    ResetWordBuffer;
    Exit;
  end;

  if not ContainsOnlyLetters(FTypedWord) then
  begin
    LogMsg(Format('boundary: пропуск, не только буквы: "%s"', [FTypedWord]));
    ResetWordBuffer;
    Exit;
  end;

  if IsExcludedWindow or IsPasswordField then
  begin
    LogMsg(Format('boundary: пропуск, исключённое окно/пароль ("%s")', [FTypedWord]));
    ResetWordBuffer;
    Exit;
  end;

  // Сохраняем слово в список слов последней строки для возможности переключения правым Ctrl
  FLastLine.Words.Add(FTypedWord);
  
  // Добавляем буфер событий клавиш для этого слова
  SetLength(FLastLine.BufferCopies, Length(FLastLine.BufferCopies) + 1);
  SetLength(FLastLine.BufferCopies[High(FLastLine.BufferCopies)], FBuffer.Count);
  for I := 0 to FBuffer.Count - 1 do
    FLastLine.BufferCopies[High(FLastLine.BufferCopies)][I] := FBuffer[I];
  
  FLastLine.StartTick := GetTickCount;

  // Строим оба варианта прочтения буфера клавиш: "как если бы была
  // активна русская раскладка" и "как если бы была активна английская".
  EnCandidate := '';
  RuCandidate := '';
  for I := 0 to FBuffer.Count - 1 do
  begin
    if KeyToChar(FBuffer[I].vkCode, FBuffer[I].scanCode, FBuffer[I].KeyState, FHklEn, Ch) then
      EnCandidate := EnCandidate + Ch;
    if KeyToChar(FBuffer[I].vkCode, FBuffer[I].scanCode, FBuffer[I].KeyState, FHklRu, Ch) then
      RuCandidate := RuCandidate + Ch;
  end;

  if (EnCandidate = '') or (RuCandidate = '') then
  begin
    LogMsg(Format('boundary: пропуск, не удалось построить кандидатов (en="%s" ru="%s")',
      [EnCandidate, RuCandidate]));
    ResetWordBuffer;
    Exit;
  end;

  // Главное правило против ложных срабатываний: если то, что реально
  // напечаталось, УЖЕ является существующим словом своего языка -
  // трогать ничего не нужно, даже если "альтернативное" прочтение
  // тоже случайно похоже на слово.
  if FTypedWordLang = langRu then
    ActiveMatch := FDicRu.Contains(FTypedWord)
  else if FTypedWordLang = langEn then
    ActiveMatch := FDicEn.Contains(FTypedWord)
  else
    ActiveMatch := False;

  LogMsg(Format('boundary: typed="%s" lang=%d en_candidate="%s" ru_candidate="%s" activeMatch=%s',
    [FTypedWord, Ord(FTypedWordLang), EnCandidate, RuCandidate, BoolToStr(ActiveMatch, True)]));

  if ActiveMatch then
  begin
    LogMsg('  -> уже валидное слово своего языка, не трогаем');
    ResetWordBuffer;
    Exit;
  end;

  if FTypedWordLang = langRu then
  begin
    AltWord := EnCandidate;
    AltMatch := FDicEn.Contains(AltWord);
    NewLang := langEn;
  end
  else if FTypedWordLang = langEn then
  begin
    AltWord := RuCandidate;
    AltMatch := FDicRu.Contains(AltWord);
    NewLang := langRu;
  end
  else
  begin
    LogMsg('  -> язык набора не определён (langUnknown), пропуск');
    ResetWordBuffer;
    Exit;
  end;

  LogMsg(Format('  -> altWord="%s" altMatch=%s', [AltWord, BoolToStr(AltMatch, True)]));

  if AltMatch and (Length(FTypedWord) >= 2) then
  begin
    LogMsg(Format('  -> ИСПРАВЛЯЮ: "%s" -> "%s"', [FTypedWord, AltWord]));
    PerformCorrection(FTypedWord, AltWord, NewLang);
  end
  else
    LogMsg('  -> альтернативного слова нет в словаре, не трогаем');

  ResetWordBuffer;
end;

procedure TAutoCorrectEngine.PerformCorrection(const OldWord, NewWord: string;
  NewLang: TAppLanguage);
begin
  SendBackspaces(Length(OldWord));
  SendUnicodeText(NewWord);
  SwitchLayoutForForeground(NewLang);

  FLastCorrection.Active := True;
  FLastCorrection.OldWord := OldWord;
  FLastCorrection.NewWord := NewWord;
  FLastCorrection.TickCount := GetTickCount;
end;

procedure TAutoCorrectEngine.SwitchLayoutForForeground(Lang: TAppLanguage);
var
  Wnd: HWND;
  TargetHkl: HKL;
begin
  Wnd := GetForegroundWindow;
  if Wnd = 0 then Exit;
  if Lang = langRu then TargetHkl := FHklRu
  else if Lang = langEn then TargetHkl := FHklEn
  else Exit;

  // Стандартный способ попросить систему сменить язык ввода для
  // конкретного окна (а не только для текущего потока).
  PostMessage(Wnd, WM_INPUTLANGCHANGEREQUEST, 0, LPARAM(TargetHkl));
end;

procedure TAutoCorrectEngine.TryRevertLastCorrection;
begin
  if not FLastCorrection.Active then Exit;
  if GetTickCount - FLastCorrection.TickCount > UNDO_TIMEOUT_MS then
  begin
    FLastCorrection.Active := False;
    Exit;
  end;

  SendBackspaces(Length(FLastCorrection.NewWord));
  SendUnicodeText(FLastCorrection.OldWord);
  FLastCorrection.Active := False;
end;

{ ---------- Обработка правого Ctrl (одиночное/двойное нажатие) ---------- }

const
  DOUBLE_CLICK_TIME_MS = 300; // Максимальный интервал между нажатиями для двойного клика

procedure TAutoCorrectEngine.HandleRightCtrlPress;
var
  NowTick: Cardinal;
begin
  NowTick := GetTickCount;
  
  // Проверяем, было ли это второе нажатие (двойной клик)
  if (NowTick - FRightCtrlPressTime <= DOUBLE_CLICK_TIME_MS) and (FRightCtrlPressCount = 1) then
  begin
    // Двойное нажатие - переключаем раскладку
    FRightCtrlPressCount := 0;
    FRightCtrlPressTime := 0;
    
    LogMsg('Right Ctrl: двойное нажатие - переключение раскладки');
    ToggleLastLine;
  end
  else
  begin
    // Одиночное нажатие - переключаем последнее слово
    FRightCtrlPressTime := NowTick;
    FRightCtrlPressCount := 1;
    
    LogMsg('Right Ctrl: одиночное нажатие - переключение последнего слова');
    ToggleLastWord;
  end;
end;

procedure TAutoCorrectEngine.ToggleLastWord;
var
  OldWord, NewWord: string;
  ActiveHkl: HKL;
  EnCandidate, RuCandidate: string;
  I: Integer;
  Ch: WideChar;
  WordIndex: Integer;
begin
  // Переключаем последнее набранное слово туда-обратно из сохранённой копии
  if FLastLine.Words.Count = 0 then
  begin
    LogMsg('ToggleLastWord: нечего переключать (пустой список слов)');
    Exit;
  end;

  // Берём последнее слово из списка
  WordIndex := FLastLine.Words.Count - 1;
  
  // Проверяем, есть ли буфер для этого слова
  if (WordIndex >= Length(FLastLine.BufferCopies)) or 
     (Length(FLastLine.BufferCopies[WordIndex]) < 2) then
  begin
    LogMsg('ToggleLastWord: нет буфера клавиш для последнего слова');
    Exit;
  end;

  // Строим оба варианта прочтения буфера клавиш из сохранённой копии
  EnCandidate := '';
  RuCandidate := '';
  for I := 0 to Length(FLastLine.BufferCopies[WordIndex]) - 1 do
  begin
    if KeyToChar(FLastLine.BufferCopies[WordIndex][I].vkCode, 
                 FLastLine.BufferCopies[WordIndex][I].scanCode, 
                 FLastLine.BufferCopies[WordIndex][I].KeyState, FHklEn, Ch) then
      EnCandidate := EnCandidate + Ch;
    if KeyToChar(FLastLine.BufferCopies[WordIndex][I].vkCode, 
                 FLastLine.BufferCopies[WordIndex][I].scanCode, 
                 FLastLine.BufferCopies[WordIndex][I].KeyState, FHklRu, Ch) then
      RuCandidate := RuCandidate + Ch;
  end;

  if (EnCandidate = '') or (RuCandidate = '') then
    Exit;

  // Определяем, какой вариант сейчас активен, и переключаем на альтернативный
  ActiveHkl := CurrentForegroundHkl;
  if HklLangId(ActiveHkl) = LANGID_RUSSIAN then
  begin
    // Сейчас русская раскладка - переключаем на английскую версию
    OldWord := RuCandidate;
    NewWord := EnCandidate;
  end
  else
  begin
    // Сейчас английская раскладка - переключаем на русскую версию
    OldWord := EnCandidate;
    NewWord := RuCandidate;
  end;

  LogMsg(Format('ToggleLastWord: "%s" -> "%s"', [OldWord, NewWord]));
  
  // Отправляем исправление
  SendBackspaces(Length(OldWord));
  SendUnicodeText(NewWord);
end;

procedure TAutoCorrectEngine.ToggleLastLine;
var
  Wnd: HWND;
  ThreadId: DWORD;
  I, WordIndex: Integer;
  OldWord, NewWord, EnCandidate, RuCandidate: string;
  Ch: WideChar;
  ActiveHkl: HKL;
begin
  // Переключаем всю последнюю строку - все слова в ней туда-обратно
  if FLastLine.Words.Count = 0 then
  begin
    LogMsg('ToggleLastLine: нечего переключать (пустой список слов)');
    Exit;
  end;

  // Получаем текущее активное окно для определения текущей раскладки
  Wnd := GetForegroundWindow;
  if Wnd = 0 then Exit;
  
  ThreadId := GetWindowThreadProcessId(Wnd, nil);
  ActiveHkl := GetKeyboardLayout(ThreadId);
  
  LogMsg(Format('ToggleLastLine: переключение %d слов в строке', [FLastLine.Words.Count]));
  
  // Проходим по всем словам в строке и переключаем каждое
  for WordIndex := 0 to FLastLine.Words.Count - 1 do
  begin
    // Проверяем, есть ли буфер для этого слова
    if (WordIndex >= Length(FLastLine.BufferCopies)) or 
       (Length(FLastLine.BufferCopies[WordIndex]) < 2) then
      Continue;

    // Строим оба варианта прочтения буфера клавиш
    EnCandidate := '';
    RuCandidate := '';
    for I := 0 to Length(FLastLine.BufferCopies[WordIndex]) - 1 do
    begin
      if KeyToChar(FLastLine.BufferCopies[WordIndex][I].vkCode, 
                   FLastLine.BufferCopies[WordIndex][I].scanCode, 
                   FLastLine.BufferCopies[WordIndex][I].KeyState, FHklEn, Ch) then
        EnCandidate := EnCandidate + Ch;
      if KeyToChar(FLastLine.BufferCopies[WordIndex][I].vkCode, 
                   FLastLine.BufferCopies[WordIndex][I].scanCode, 
                   FLastLine.BufferCopies[WordIndex][I].KeyState, FHklRu, Ch) then
        RuCandidate := RuCandidate + Ch;
    end;

    if (EnCandidate = '') or (RuCandidate = '') then
      Continue;

    // Определяем, какой вариант сейчас активен, и переключаем на альтернативный
    if HklLangId(ActiveHkl) = LANGID_RUSSIAN then
    begin
      // Сейчас русская раскладка - переключаем на английскую версию
      OldWord := RuCandidate;
      NewWord := EnCandidate;
    end
    else
    begin
      // Сейчас английская раскладка - переключаем на русскую версию
      OldWord := EnCandidate;
      NewWord := RuCandidate;
    end;

    LogMsg(Format('ToggleLastLine: слово %d: "%s" -> "%s"', [WordIndex + 1, OldWord, NewWord]));
    
    // Отправляем исправление
    SendBackspaces(Length(OldWord));
    SendUnicodeText(NewWord);
  end;
end;

end.
