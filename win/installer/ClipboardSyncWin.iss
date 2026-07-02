#define MyAppName "Clipboard Sync"
#define MyAppExeName "ClipboardSyncWin.exe"
#define MyAppPublisher "qiudaomao"
#define MyAppVersion GetEnv("CLIPBOARD_SYNC_VERSION")
#if MyAppVersion == ""
  #define MyAppVersion "0.1.1"
#endif
#define MyReleaseVersion GetEnv("CLIPBOARD_SYNC_RELEASE_VERSION")
#if MyReleaseVersion == ""
  #define MyReleaseVersion "v0.1.1"
#endif

[Setup]
AppId={{A7F12E1D-3D2E-4E14-B3F2-38F67F9B4A7B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\Clipboard Sync
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputBaseFilename=ClipboardSyncWinSetup-{#MyReleaseVersion}
OutputDir=..\..\artifacts\windows
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
SetupIconFile=..\ClipboardSyncWin\Assets\clipboard-sync-icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes
RestartApplications=no

[Files]
Source: "..\ClipboardSyncWin\bin\Release\net8.0-windows\win-x64\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
