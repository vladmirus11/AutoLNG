program PuntoClone;

uses
  Vcl.Forms,
  uMain in 'uMain.pas' {MainForm},
  uAutoCorrect in 'uAutoCorrect.pas',
  uLayoutCore in 'uLayoutCore.pas',
  uDictionary in 'uDictionary.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
