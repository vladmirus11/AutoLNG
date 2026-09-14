unit uDictionary;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  // Хранит слово -> ранг (позиция в исходном частотном списке, 0 = самое
  // частое). Ранг сейчас не используется в принятии решений напрямую,
  // но пригодится, если понадобится взвешивать неоднозначные случаи
  // (когда слово "похоже" валидно в обоих языках).
  TWordDictionary = class
  private
    FWords: TDictionary<string, Integer>;
  public
    constructor Create;
    destructor Destroy; override;

    procedure LoadFromFile(const FileName: string);
    function Contains(const AWord: string): Boolean;
    function TryGetRank(const AWord: string; out Rank: Integer): Boolean;
    function Count: Integer;
  end;

implementation

constructor TWordDictionary.Create;
begin
  inherited Create;
  FWords := TDictionary<string, Integer>.Create;
end;

destructor TWordDictionary.Destroy;
begin
  FWords.Free;
  inherited;
end;

procedure TWordDictionary.LoadFromFile(const FileName: string);
var
  SL: TStringList;
  I: Integer;
  W: string;
begin
  if not FileExists(FileName) then
    raise Exception.CreateFmt('Файл словаря не найден: %s', [FileName]);

  SL := TStringList.Create;
  try
    // Списки популярных слов обычно в UTF-8 (в т.ч. без BOM для
    // английского файла) - TEncoding.UTF8 корректно читает оба варианта.
    SL.LoadFromFile(FileName, TEncoding.UTF8);
    for I := 0 to SL.Count - 1 do
    begin
      W := LowerCase(Trim(SL[I]));
      if (W = '') then
        Continue;
      if not FWords.ContainsKey(W) then
        FWords.Add(W, I); // первое вхождение = наивысший ранг (частотный список)
    end;
  finally
    SL.Free;
  end;
end;

function TWordDictionary.Contains(const AWord: string): Boolean;
begin
  Result := FWords.ContainsKey(LowerCase(AWord));
end;

function TWordDictionary.TryGetRank(const AWord: string; out Rank: Integer): Boolean;
begin
  Result := FWords.TryGetValue(LowerCase(AWord), Rank);
end;

function TWordDictionary.Count: Integer;
begin
  Result := FWords.Count;
end;

end.
