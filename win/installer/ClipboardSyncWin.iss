#define MyAppName "Clipboard Sync"
#define MyAppExeName "ClipboardSync.exe"
#define MyServiceExeName "ClipboardSync.InputService.exe"
#define MyServiceName "ClipboardSyncInputService"
#define MyServiceDisplayName "Clipboard Sync Input Service"
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
; Machine-wide install under Program Files. This is required by the secure-desktop input
; service: registering a LocalSystem service needs elevation, and the service only trusts a
; ClipboardSync.exe client that lives under Program Files (see InputAgent's trust check), so a
; per-user LocalAppData install cannot drive input on the lock screen.
DefaultDirName={autopf}\Clipboard Sync
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputBaseFilename=ClipboardSyncSetup-{#MyReleaseVersion}
OutputDir=..\..\artifacts\windows
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; A complete version resource on Setup.exe itself. Reputation heuristics treat an installer
; that declares no publisher, product or description as more suspicious than one that does;
; this costs nothing and is what a shipped installer should carry regardless. It is not a
; substitute for signing the binaries, which is the only thing that actually builds trust.
VersionInfoVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoProductName={#MyAppName}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
VersionInfoCopyright=Copyright (c) 2026 {#MyAppPublisher}
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
SetupIconFile=..\ClipboardSyncWin\Assets\clipboard-sync-icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes
RestartApplications=no

[InstallDelete]
; The executable was renamed from ClipboardSyncWin to ClipboardSync; sweep the old-name files
; so an upgraded install doesn't keep a stale second copy of the app.
Type: files; Name: "{app}\ClipboardSyncWin.exe"
Type: files; Name: "{app}\ClipboardSyncWin.dll"
Type: files; Name: "{app}\ClipboardSyncWin.pdb"
Type: files; Name: "{app}\ClipboardSyncWin.deps.json"
Type: files; Name: "{app}\ClipboardSyncWin.runtimeconfig.json"

[Files]
Source: "..\ClipboardSyncWin\bin\Release\net8.0-windows\win-x64\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; The input service lives in a subdirectory so the agent's trusted-client path
; ({service dir}\..\ClipboardSync.exe) resolves to the installed client.
Source: "..\ClipboardSyncInputService\bin\Release\net8.0-windows\win-x64\publish\*"; DestDir: "{app}\InputService"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
; Launch de-elevated so the tray app runs as the logged-in user, not as the elevated installer.
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall runasoriginaluser

[Code]
const
  ServiceName = '{#MyServiceName}';

function ScExec(const Params: string): Integer;
var
  ResultCode: Integer;
begin
  if not Exec(ExpandConstant('{sys}\sc.exe'), Params, '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode) then
    ResultCode := -1;
  Result := ResultCode;
end;

function ServiceExists: Boolean;
begin
  { sc query returns 1060 (ERROR_SERVICE_DOES_NOT_EXIST) when the service is absent. }
  Result := ScExec('query ' + ServiceName) <> 1060;
end;

procedure StopAndDeleteService;
begin
  if not ServiceExists then
    exit;
  { Stop first so the service releases ClipboardSync.InputService.exe before it is
    overwritten (upgrade) or deleted (uninstall). }
  ScExec('stop ' + ServiceName);
  { Give the SCM a moment to tear the service (and its per-session agents) down. }
  Sleep(3000);
  ScExec('delete ' + ServiceName);
  Sleep(1000);
end;

procedure RegisterService;
var
  ServiceExe: string;
  BinPath: string;
begin
  ServiceExe := ExpandConstant('{app}\InputService\{#MyServiceExeName}');
  { ImagePath must quote the exe separately from its argument so the SCM parses them
    correctly when the path contains spaces (e.g. C:\Program Files\Clipboard Sync). }
  BinPath := '"\"' + ServiceExe + '\" --service"';
  ScExec('create ' + ServiceName + ' binPath= ' + BinPath +
    ' start= auto obj= LocalSystem DisplayName= "{#MyServiceDisplayName}"');
  ScExec('description ' + ServiceName +
    ' "Delivers Clipboard Sync remote input to the secure (lock screen) desktop."');
  ScExec('start ' + ServiceName);
end;

procedure RemoveOldPerUserInstall;
var
  UninstallString: string;
  OldDir: string;
  ResultCode: Integer;
begin
  { Builds up to 0.1.x installed per-user under %LOCALAPPDATA%\Programs with the same AppId.
    Now that we install machine-wide under Program Files, run the old uninstaller (best effort)
    and sweep any leftovers so the user isn't left with a second, stale copy. This reaches only
    the *current* user's per-user install; a copy made by a different account is left untouched.
    The launch-at-login entry (HKCU\...\Run\ClipboardSync) is self-repaired to the new path by
    the app when the post-install launch starts it, so it is intentionally not touched here. }
  if RegQueryStringValue(HKCU,
      'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{A7F12E1D-3D2E-4E14-B3F2-38F67F9B4A7B}_is1',
      'UninstallString', UninstallString) then
  begin
    UninstallString := RemoveQuotes(UninstallString);
    if FileExists(UninstallString) then
      Exec(UninstallString, '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES', '', SW_HIDE,
        ewWaitUntilTerminated, ResultCode);
  end;

  { Fallback in case the uninstaller was missing or left files behind. Guaranteed distinct from
    the new Program Files location, so this can never touch the fresh install. }
  OldDir := ExpandConstant('{localappdata}\Programs\Clipboard Sync');
  if DirExists(OldDir) then
    DelTree(OldDir, True, True, True);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  { Runs before files are copied. Remove the legacy per-user install first, then make sure any
    prior service releases its exe before it is overwritten. }
  RemoveOldPerUserInstall;
  StopAndDeleteService;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    RegisterService;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    StopAndDeleteService;
end;
