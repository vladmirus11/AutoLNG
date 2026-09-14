unit uLayoutCore;

{
  Ключевая идея модуля: вместо того чтобы вручную городить таблицу
  "английская буква -> русская буква", мы используем саму систему Windows.

  Функция ToUnicodeEx умеет по virtual-key + scan-code + состоянию клавиш
  (Shift/CapsLock) сказать, какой символ получился бы, если бы была активна
  ЛЮБАЯ конкретная раскладка (параметр HKL) — при этом реальная активная
  раскладка в системе не переключается.

  Это даёт нам два "кандидата" для каждой нажатой клавиши:
    - что напечаталось бы, если бы была активна русская раскладка
    - что напечаталось бы, если бы была активна английская раскладка
  независимо от того, какая раскладка активна на самом деле.
}

interface

uses
  Winapi.Windows, System.SysUtils;

const
  KLID_RUSSIAN = '00000419';
  KLID_ENGLISH = '00000409';

type
  // Важно: это должен быть ИМЕНОВАННЫЙ АЛИАС на системный тип TKeyboardState
  // (Winapi.Windows), а не отдельно объявленный array[0..255] of Byte.
  // Даже при идентичной структуре Delphi считает такие типы разными,
  // и ToUnicodeEx (принимающий именно TKeyboardState) перестаёт находиться
  // среди перегрузок -> ошибка E2250.
  TKeyboardState256 = Winapi.Windows.TKeyboardState;

function LoadLayoutHandle(const KLID: string): HKL;

// Возвращает True и символ Ch, если клавиша с данным vkCode/scanCode
// и состоянием KeyState печатает ровно один символ в раскладке HKL_.
function KeyToChar(vkCode, scanCode: DWORD; const KeyState: TKeyboardState256;
  HKL_: HKL; out Ch: WideChar): Boolean;

implementation

function LoadLayoutHandle(const KLID: string): HKL;
begin
  // KLF_NOTELLSHELL - зарегистрировать раскладку, не уведомляя шелл
  // и не делая её активной. KLF_SUBSTITUTE_OK - разрешить замену,
  // если такая раскладка уже загружена под другим ID.
  Result := LoadKeyboardLayout(PChar(KLID), KLF_NOTELLSHELL or KLF_SUBSTITUTE_OK);
  if Result = 0 then
    RaiseLastOSError;
end;

function KeyToChar(vkCode, scanCode: DWORD; const KeyState: TKeyboardState256;
  HKL_: HKL; out Ch: WideChar): Boolean;
var
  Buf: array[0..4] of WideChar;
  R: Integer;
begin
  Result := False;
  Ch := #0;
  FillChar(Buf, SizeOf(Buf), 0);
  // Последний параметр (0) - флаги; бит 0x1 (не менять состояние "мёртвых"
  // клавиш вызывающего потока) добавлен в более новых Windows SDK,
  // в XE2 его может не быть в декларации - поэтому передаём 0 и просто
  // не используем "мёртвые" клавиши (диакритику) в этой программе.
  R := ToUnicodeEx(vkCode, scanCode, KeyState, PWideChar(@Buf[0]), Length(Buf), 0, HKL_);
  if R = 1 then
  begin
    Ch := Buf[0];
    Result := True;
  end;
  // R = 0 (нет символа, например Ctrl/чистый модификатор),
  // R < 0 (мёртвая клавиша), R > 1 (несколько символов) - во всех этих
  // случаях считаем, что однозначного символа нет.
end;

end.
