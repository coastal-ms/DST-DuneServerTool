; ============================================================
;  Dune Server - Inno Setup installer script
;  Output: app/installer/output/DuneServerSetup.exe
; ============================================================
;
;  Admin requirements (preserved at every layer):
;    1. Setup itself requires admin (PrivilegesRequired=admin)
;       -> needed to write to Program Files
;    2. DuneServer.exe has UAC manifest embedded (-requireAdmin via ps2exe)
;       -> launching from Start Menu auto-elevates with UAC prompt
;    3. dune-server.ps1 has '#Requires -RunAsAdministrator' at line 1
;       -> child pwsh processes inherit elevation from the parent .exe
;
;  Installs to:   {autopf}\Dune Server\         (= Program Files\Dune Server\)
;  User data:     %APPDATA%\DuneServer\         (config, logs, boot-times.json)
;                 -> NOT touched by install or uninstall (preserves user config)

#define MyAppName        "Dune Server"
#define MyAppVersion "4.0.7"
#define MyAppPublisher   "Dune Awakening Self-Hosted Tool"
#define MyAppURL         "https://github.com/coastal-ms/Simple-Dune-Server-Management-Tool"
#define MyAppExeName     "DuneServer.exe"
#define MyAppId          "{{B3F8A2C1-7E5D-4F9A-8B2C-1D6E3A4F5C7D}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
VersionInfoVersion={#MyAppVersion}.0
DefaultDirName={autopf}\Dune Server
DefaultGroupName=Dune Server
DisableProgramGroupPage=no
DisableDirPage=no
DisableReadyPage=no
LicenseFile=
OutputDir=output
OutputBaseFilename=DuneServerSetup
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName} {#MyAppVersion}
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern

; --- Admin requirements (LAYER 1: setup itself) ---
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=

; OS targeting (Inno Setup 6 itself already requires Win10 1809+)
MinVersion=10.0
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
; The compiled WPF host app (with embedded UAC manifest)
Source: "..\build\output\DuneServer.exe"; DestDir: "{app}"; Flags: ignoreversion

; The business logic script (called by DuneServer.exe via -Cmd)
Source: "..\..\dune-server.ps1"; DestDir: "{app}"; Flags: ignoreversion

; Standalone icon for shortcuts that point at the .ps1 etc.
Source: "..\assets\icon.ico"; DestDir: "{app}\assets"; Flags: ignoreversion

[Icons]
; Start Menu shortcut (always created)
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Comment: "Dune Awakening server management"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"

; Desktop shortcut (only if user ticked the box on the Tasks page)
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Launch immediately after install if the user wants. The app's embedded
; UAC manifest will trigger its own elevation prompt; postinstall preserves
; the original elevated context.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent runascurrentuser

[UninstallDelete]
; Belt-and-suspenders: clear any junk inside install dir that isn't tracked
Type: filesandordirs; Name: "{app}"

[Code]
// ---------------------------------------------------------------
//  Existing user detection
//
//  On first install, look for a legacy dune-server.config in common
//  locations (Desktop, OneDrive subfolders) and inform the user that
//  they should copy it to %APPDATA%\DuneServer\ before launching the
//  app.  We do NOT auto-copy because we can't guess which copy is
//  authoritative if there are several.
// ---------------------------------------------------------------
function FindLegacyConfig(): string;
var
  candidates: TArrayOfString;
  i: Integer;
  appdataCfg: string;
begin
  Result := '';

  // If APPDATA config already exists, no migration needed
  appdataCfg := ExpandConstant('{userappdata}\DuneServer\dune-server.config');
  if FileExists(appdataCfg) then
    Exit;

  SetArrayLength(candidates, 6);
  candidates[0] := ExpandConstant('{userdesktop}\GH Dune Server Tool\dune-server.config');
  candidates[1] := ExpandConstant('{userdesktop}\Simple-Dune-Server-Management-Tool\dune-server.config');
  candidates[2] := ExpandConstant('{userdesktop}\dune-server.config');
  candidates[3] := ExpandConstant('{%USERPROFILE}\OneDrive\Desktop\GH Dune Server Tool\dune-server.config');
  candidates[4] := ExpandConstant('{%USERPROFILE}\Documents\dune-server.config');
  candidates[5] := ExpandConstant('{%USERPROFILE}\Downloads\Simple-Dune-Server-Management-Tool-main\dune-server.config');

  for i := 0 to GetArrayLength(candidates) - 1 do
  begin
    if FileExists(candidates[i]) then
    begin
      Result := candidates[i];
      Exit;
    end;
  end;
end;

procedure MigrateLegacyConfig(srcPath: string);
var
  destDir, destPath: string;
begin
  destDir  := ExpandConstant('{userappdata}\DuneServer');
  destPath := destDir + '\dune-server.config';

  if not DirExists(destDir) then
    CreateDir(destDir);

  if CopyFile(srcPath, destPath, False) then
    Log('Migrated config: ' + srcPath + ' -> ' + destPath)
  else
    Log('Migration failed for: ' + srcPath);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  legacy: string;
  msg: string;
begin
  if CurStep = ssPostInstall then
  begin
    legacy := FindLegacyConfig();
    if legacy <> '' then
    begin
      msg :=
        'Existing config detected:' + #13#10 + #13#10 +
        legacy + #13#10 + #13#10 +
        'Copy it to %APPDATA%\DuneServer\dune-server.config so the new app picks up your existing settings?';
      if MsgBox(msg, mbConfirmation, MB_YESNO) = IDYES then
        MigrateLegacyConfig(legacy);
    end;
  end;
end;
