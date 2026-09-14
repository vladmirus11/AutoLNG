object MainForm: TMainForm
  Left = 0
  Top = 0
  BorderStyle = bsToolWindow
  Caption = 'PuntoClone'
  ClientHeight = 100
  ClientWidth = 200
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = True
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  PixelsPerInch = 96
  TextHeight = 13
  object TrayIcon: TTrayIcon
    PopupMenu = PopupMenuTray
    OnDblClick = TrayIconDblClick
    Left = 80
    Top = 40
  end
  object PopupMenuTray: TPopupMenu
    Left = 80
    Top = 8
    object MenuItemEnabled: TMenuItem
      Caption = #1042#1082#1083#1102#1095#1077#1085#1086
      Checked = True
      OnClick = MenuItemEnabledClick
    end
    object MenuItemSep: TMenuItem
      Caption = '-'
    end
    object MenuItemExit: TMenuItem
      Caption = #1042#1099#1093#1086#1076
      OnClick = MenuItemExitClick
    end
  end
end
