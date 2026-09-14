unit uMain;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.Menus,
  Vcl.ExtCtrls, uAutoCorrect;

type
  TMainForm = class(TForm)
    TrayIcon: TTrayIcon;
    PopupMenuTray: TPopupMenu;
    MenuItemEnabled: TMenuItem;
    MenuItemSep: TMenuItem;
    MenuItemExit: TMenuItem;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure MenuItemEnabledClick(Sender: TObject);
    procedure MenuItemExitClick(Sender: TObject);
    procedure TrayIconDblClick(Sender: TObject);
  private
    procedure UpdateTrayHint;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.dfm}

procedure TMainForm.FormCreate(Sender: TObject);
var
  BasePath, DictRu, DictEn: string;
begin
  // Словари лежат рядом с exe-файлом, как и просил пользователь.
  BasePath := ExtractFilePath(ParamStr(0));
  DictRu := BasePath + '10000-russian-words.txt';
  DictEn := BasePath + 'google-10000-english-no-swears.txt';

  try
    GEngine := TAutoCorrectEngine.Create(DictRu, DictEn);
    GEngine.InstallHook;
  except
    on E: Exception do
    begin
      MessageDlg('Не удалось запустить движок коррекции раскладки:' + sLineBreak +
        E.Message, mtError, [mbOK], 0);
      Application.Terminate;
      Exit;
    end;
  end;

  MenuItemEnabled.Checked := True;
  UpdateTrayHint;
  TrayIcon.Visible := True;

  // Прячем окно - программа живёт только в трее.
  // (BorderStyle = bsToolWindow в .dfm уже не даёт форме появляться
  // в панели задач; отдельное свойство ShowInTaskBar в VCL не существует
  // - это FireMonkey-шная штука, тут её нет.)
  Hide;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  FreeAndNil(GEngine);
end;

procedure TMainForm.UpdateTrayHint;
begin
  if Assigned(GEngine) and GEngine.Enabled then
    TrayIcon.Hint := 'Переключатель раскладки: включён'
  else
    TrayIcon.Hint := 'Переключатель раскладки: выключен';
end;

procedure TMainForm.MenuItemEnabledClick(Sender: TObject);
begin
  MenuItemEnabled.Checked := not MenuItemEnabled.Checked;
  if Assigned(GEngine) then
    GEngine.Enabled := MenuItemEnabled.Checked;
  UpdateTrayHint;
end;

procedure TMainForm.MenuItemExitClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.TrayIconDblClick(Sender: TObject);
begin
  MenuItemEnabledClick(Sender);
end;

end.
