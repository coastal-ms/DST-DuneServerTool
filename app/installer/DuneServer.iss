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
#define MyAppVersion "4.4.0"
#define MyAppPublisher   "Dune Awakening Self-Hosted Tool"
#define MyAppURL         "https://github.com/Neil-PSP/Simple-Dune-Server-Management-Tool"
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
// ============================================================
//  First-run configuration wizard
//
//  Adds 5 custom pages to the installer that collect everything
//  the app needs (server folder, SSH key, dune-admin.exe, Windows
//  username, port-check mode) using native Browse buttons. On
//  install, writes the values to %APPDATA%\DuneServer\dune-server.config
//  so the app launches fully configured.
//
//  Behaviour:
//    - If %APPDATA%\DuneServer\dune-server.config already exists,
//      ALL custom pages are skipped (upgrade path - preserve user config).
//    - If a legacy config is found on Desktop/OneDrive/etc., the user
//      is asked once whether to import it. If yes, pages are pre-filled
//      from the legacy values; if no, sensible auto-detected defaults
//      are used.
// ============================================================

var
  ServerDirPage:   TInputDirWizardPage;
  SshKeyPage:      TInputFileWizardPage;
  AdminExePage:    TInputFileWizardPage;
  AdminDownloadBtn:   TNewButton;
  AdminDownloadLabel: TNewStaticText;
  UserPage:        TInputQueryWizardPage;
  PortModePage:    TInputOptionWizardPage;
  SkipConfigPages: Boolean;

// ---------- helpers ----------

function FindLegacyConfig(): string;
var
  candidates: TArrayOfString;
  i: Integer;
begin
  Result := '';
  SetArrayLength(candidates, 8);
  candidates[0] := ExpandConstant('{userdesktop}\GH Dune Server Tool\dune-server.config');
  candidates[1] := ExpandConstant('{userdesktop}\Simple-Dune-Server-Management-Tool\dune-server.config');
  candidates[2] := ExpandConstant('{userdesktop}\dune-server.config');
  candidates[3] := ExpandConstant('{%USERPROFILE}\OneDrive\Desktop\GH Dune Server Tool\dune-server.config');
  candidates[4] := ExpandConstant('{%USERPROFILE}\Documents\dune-server.config');
  candidates[5] := ExpandConstant('{%USERPROFILE}\Downloads\Simple-Dune-Server-Management-Tool-main\dune-server.config');
  candidates[6] := ExpandConstant('{%USERPROFILE}\OneDrive\1CopilotCLI - Work\Simple-Dune-Server-Management-Tool\dune-server.config');
  candidates[7] := ExpandConstant('{%USERPROFILE}\OneDrive\Desktop\Simple-Dune-Server-Management-Tool\dune-server.config');

  for i := 0 to GetArrayLength(candidates) - 1 do
    if FileExists(candidates[i]) then begin Result := candidates[i]; Exit; end;
end;

// Read one key=value out of a legacy config file (empty string if missing)
function ReadCfgKey(path, key: string): string;
var
  lines: TArrayOfString;
  i, eq: Integer;
  k, v, line: string;
begin
  Result := '';
  if not FileExists(path) then Exit;
  if not LoadStringsFromFile(path, lines) then Exit;
  for i := 0 to GetArrayLength(lines) - 1 do
  begin
    line := Trim(lines[i]);
    if (line = '') or (Copy(line, 1, 1) = '#') then Continue;
    eq := Pos('=', line);
    if eq = 0 then Continue;
    k := Trim(Copy(line, 1, eq - 1));
    v := Trim(Copy(line, eq + 1, Length(line)));
    if CompareText(k, key) = 0 then begin Result := v; Exit; end;
  end;
end;

// Find the first existing path from a list, else return first non-empty
function FirstExistingPath(paths: array of string; checkDir: Boolean): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to GetArrayLength(paths) - 1 do
  begin
    if checkDir then
    begin
      if DirExists(paths[i]) then begin Result := paths[i]; Exit; end;
    end
    else
    begin
      if FileExists(paths[i]) then begin Result := paths[i]; Exit; end;
    end;
  end;
  if GetArrayLength(paths) > 0 then Result := paths[0];
end;

function AutoDetectServerDir(): string;
var
  candidates: array of string;
begin
  SetArrayLength(candidates, 5);
  candidates[0] := 'C:\Program Files (x86)\Steam\steamapps\common\Dune Awakening Self-Hosted Server';
  candidates[1] := 'C:\Program Files\Steam\steamapps\common\Dune Awakening Self-Hosted Server';
  candidates[2] := 'D:\SteamLibrary\steamapps\common\Dune Awakening Self-Hosted Server';
  candidates[3] := 'E:\SteamLibrary\steamapps\common\Dune Awakening Self-Hosted Server';
  candidates[4] := 'X:\SteamLibrary\steamapps\common\Dune Awakening Self-Hosted Server';
  Result := FirstExistingPath(candidates, True);
end;

function AutoDetectSshKey(serverDir: string): string;
var
  candidates: array of string;
begin
  SetArrayLength(candidates, 3);
  candidates[0] := ExpandConstant('{localappdata}\DuneAwakeningServer\sshKey');
  candidates[1] := ExpandConstant('{%USERPROFILE}\.ssh\dune');
  if serverDir <> '' then
    candidates[2] := serverDir + '\sshKey'
  else
    candidates[2] := '';
  Result := FirstExistingPath(candidates, False);
end;

function AutoDetectAdminExe(): string;
var
  candidates: array of string;
begin
  SetArrayLength(candidates, 3);
  candidates[0] := ExpandConstant('{userdesktop}\dune-admin\dune-admin.exe');
  candidates[1] := ExpandConstant('{%USERPROFILE}\dune-admin\dune-admin.exe');
  candidates[2] := ExpandConstant('{userdesktop}\dune-admin-main\dune-admin.exe');
  Result := FirstExistingPath(candidates, False);
end;

// ---------- "Download latest dune-admin" button handler ----------

// Builds the PowerShell snippet that downloads the latest windows_amd64.zip
// asset from Icehunter/dune-admin, extracts it into $InstallDir, and writes
// the absolute path of the extracted dune-admin.exe to $PathOut.
function BuildDownloadScript(): string;
begin
  Result :=
    'param([Parameter(Mandatory)][string]$InstallDir, [Parameter(Mandatory)][string]$PathOut)' + #13#10 +
    '$ErrorActionPreference = ''Stop''' + #13#10 +
    '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12' + #13#10 +
    '$h = @{ ''User-Agent'' = ''DuneServerInstaller'' }' + #13#10 +
    '$r = Invoke-RestMethod -Headers $h -Uri ''https://api.github.com/repos/Icehunter/dune-admin/releases/latest'' -TimeoutSec 30' + #13#10 +
    '$asset = $r.assets | Where-Object { $_.name -like ''*windows_amd64.zip'' } | Select-Object -First 1' + #13#10 +
    'if (-not $asset) { throw ''No *_windows_amd64.zip asset found in the latest release.'' }' + #13#10 +
    'if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }' + #13#10 +
    '$tmpZip = Join-Path $env:TEMP $asset.name' + #13#10 +
    'Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip -Headers $h -UseBasicParsing -TimeoutSec 180' + #13#10 +
    'Expand-Archive -Path $tmpZip -DestinationPath $InstallDir -Force' + #13#10 +
    'Remove-Item $tmpZip -ErrorAction SilentlyContinue' + #13#10 +
    '$exe = Get-ChildItem -Path $InstallDir -Filter ''dune-admin.exe'' -Recurse | Select-Object -First 1 -ExpandProperty FullName' + #13#10 +
    'if (-not $exe) { throw ''dune-admin.exe was not found after extracting.'' }' + #13#10 +
    'Set-Content -Path $PathOut -Value $exe -Encoding ASCII' + #13#10;
end;

procedure OnAdminDownloadClick(Sender: TObject);
var
  defaultDir, chosenDir: string;
  psPath, outPath, scriptBody, exePath: string;
  exePathA: AnsiString;
  resultCode: Integer;
  ok: Boolean;
begin
  // Default to whatever folder the user already typed (if any), else Desktop\dune-admin
  defaultDir := ExtractFilePath(AdminExePage.Values[0]);
  if defaultDir = '' then
    defaultDir := ExpandConstant('{userdesktop}\dune-admin');
  // ExtractFilePath includes the trailing slash; BrowseForFolder is fine with it
  chosenDir := defaultDir;

  if not BrowseForFolder(
       'Choose where to install dune-admin. A new "dune-admin" folder is a good choice if you don''t already have one.',
       chosenDir, True) then
    Exit;

  // Strip any trailing backslash
  if (Length(chosenDir) > 0) and (chosenDir[Length(chosenDir)] = '\') then
    chosenDir := Copy(chosenDir, 1, Length(chosenDir) - 1);

  if not DirExists(chosenDir) then
  begin
    if not ForceDirectories(chosenDir) then
    begin
      MsgBox('Could not create folder:' + #13#10 + chosenDir, mbError, MB_OK);
      Exit;
    end;
  end;

  // Write the helper script and the output-path file location into {tmp}
  psPath  := ExpandConstant('{tmp}\get-dune-admin.ps1');
  outPath := ExpandConstant('{tmp}\dune-admin-path.txt');
  if FileExists(outPath) then DeleteFile(outPath);

  scriptBody := BuildDownloadScript();
  if not SaveStringToFile(psPath, scriptBody, False) then
  begin
    MsgBox('Could not write temp script to ' + psPath, mbError, MB_OK);
    Exit;
  end;

  // Disable the button and show "downloading..." so it's obvious something
  // is happening while powershell blocks.
  AdminDownloadBtn.Enabled  := False;
  AdminDownloadBtn.Caption  := 'Downloading...';
  AdminDownloadLabel.Caption := 'Contacting GitHub - this may take 10-30 seconds...';
  AdminDownloadLabel.Visible := True;
  WizardForm.Cursor := crHourGlass;
  WizardForm.Refresh;

  try
    ok := Exec('powershell.exe',
               '-NoProfile -ExecutionPolicy Bypass -File "' + psPath +
                 '" -InstallDir "' + chosenDir + '" -PathOut "' + outPath + '"',
               '', SW_HIDE, ewWaitUntilTerminated, resultCode);
  finally
    WizardForm.Cursor := crDefault;
    AdminDownloadBtn.Enabled := True;
    AdminDownloadBtn.Caption := 'Download Latest from GitHub...';
  end;

  if not ok then
  begin
    AdminDownloadLabel.Caption := 'Failed to launch PowerShell.';
    MsgBox('Could not launch powershell.exe.', mbError, MB_OK);
    Exit;
  end;

  if resultCode <> 0 then
  begin
    AdminDownloadLabel.Caption := 'Download failed (PowerShell exit code ' + IntToStr(resultCode) + ').';
    MsgBox(
      'Download failed (PowerShell exit code ' + IntToStr(resultCode) + ').' + #13#10 + #13#10 +
      'Most common causes:' + #13#10 +
      ' - No internet connection' + #13#10 +
      ' - GitHub API rate limit (60 requests/hour for unauthenticated users)' + #13#10 +
      ' - The destination folder is not writable' + #13#10 + #13#10 +
      'You can also download manually from:' + #13#10 +
      'https://github.com/Icehunter/dune-admin/releases',
      mbError, MB_OK);
    Exit;
  end;

  if not LoadStringFromFile(outPath, exePathA) then
  begin
    AdminDownloadLabel.Caption := 'Download finished but path file is missing.';
    Exit;
  end;
  exePath := Trim(String(exePathA));

  if (exePath = '') or (not FileExists(exePath)) then
  begin
    AdminDownloadLabel.Caption := 'Download finished but dune-admin.exe was not found.';
    MsgBox('Download completed but dune-admin.exe was not found at:' + #13#10 + exePath, mbError, MB_OK);
    Exit;
  end;

  AdminExePage.Values[0] := exePath;
  AdminDownloadLabel.Caption := 'Downloaded: ' + exePath;
end;

// ---------- wizard wiring ----------

procedure InitializeWizard();
var
  legacy: string;
  importLegacy: Boolean;
  defServer, defSsh, defAdmin, defUser, defMode: string;
  appdataCfg: string;
begin
  // If APPDATA config already exists, skip the whole config-collection flow
  // (this is an upgrade - don't blow away the user's settings).
  appdataCfg := ExpandConstant('{userappdata}\DuneServer\dune-server.config');
  SkipConfigPages := FileExists(appdataCfg);

  // If we found a legacy config but no APPDATA config yet, offer to import.
  importLegacy := False;
  legacy := '';
  if not SkipConfigPages then
  begin
    legacy := FindLegacyConfig();
    if legacy <> '' then
    begin
      if MsgBox(
           'A previous Dune Server config was found at:' + #13#10 + #13#10 +
           legacy + #13#10 + #13#10 +
           'Use those values as the defaults on the next few pages?' + #13#10 + #13#10 +
           '(You can still edit anything before installing.)',
           mbConfirmation, MB_YESNO) = IDYES then
        importLegacy := True;
    end;
  end;

  // Compute defaults
  if importLegacy then
  begin
    defServer := ReadCfgKey(legacy, 'SteamPath');
    defSsh    := ReadCfgKey(legacy, 'SshKey');
    defAdmin  := ReadCfgKey(legacy, 'DuneAdminExe');
    defUser   := ReadCfgKey(legacy, 'WindowsUser');
    defMode   := ReadCfgKey(legacy, 'PortCheckMode');
  end
  else
  begin
    defServer := '';
    defSsh    := '';
    defAdmin  := '';
    defUser   := '';
    defMode   := '';
  end;

  if defServer = '' then defServer := AutoDetectServerDir();
  if defSsh    = '' then defSsh    := AutoDetectSshKey(defServer);
  if defAdmin  = '' then defAdmin  := AutoDetectAdminExe();
  if defUser   = '' then defUser   := ExpandConstant('{username}');
  if defMode   = '' then defMode   := 'builtin';

  // Page 1: Server install folder (DirPage with Browse)
  ServerDirPage := CreateInputDirPage(wpSelectDir,
    'Dune Awakening Server Folder',
    'Where is the dedicated server installed?',
    'Pick the folder that contains the "battlegroup-management" subfolder. ' +
    'If you don''t have the dedicated server installed yet you can leave this ' +
    'as-is and re-run setup later.',
    False, '');
  ServerDirPage.Add('Server folder:');
  ServerDirPage.Values[0] := defServer;

  // Page 2: SSH key (FilePage with Browse)
  SshKeyPage := CreateInputFilePage(ServerDirPage.ID,
    'SSH Private Key',
    'Where is the SSH private key for the Hyper-V VM?',
    'The Dune Awakening dedicated server installer normally puts this at ' +
    '%LOCALAPPDATA%\DuneAwakeningServer\sshKey - that path is filled in below ' +
    'if it exists. Click Browse to pick a different one.');
  SshKeyPage.Add('SSH key file:', 'All files (*.*)|*.*', '');
  SshKeyPage.Values[0] := defSsh;

  // Page 3: dune-admin.exe (FilePage, optional, with a Download button)
  AdminExePage := CreateInputFilePage(SshKeyPage.ID,
    'Dune Admin Tool (optional)',
    'Where is dune-admin.exe?',
    'Optional. Icehunter''s dune-admin tool provides a player / inventory admin ' +
    'panel. Use the "Download Latest from GitHub..." button below to grab the ' +
    'newest release and pick where to put it - the path will fill in ' +
    'automatically.' + #13#10 + #13#10 + 'Leave blank to skip; the "Dune Admin" ' +
    'button will stay hidden until you set this later.');
  AdminExePage.Add('dune-admin.exe (optional):', 'Executables (*.exe)|*.exe', 'exe');
  AdminExePage.Values[0] := defAdmin;

  // "Download Latest from GitHub..." button on the same page
  AdminDownloadBtn := TNewButton.Create(WizardForm);
  AdminDownloadBtn.Parent  := AdminExePage.Surface;
  AdminDownloadBtn.Caption := 'Download Latest from GitHub...';
  AdminDownloadBtn.Left    := AdminExePage.Edits[0].Left;
  AdminDownloadBtn.Top     := AdminExePage.Edits[0].Top + AdminExePage.Edits[0].Height + ScaleY(18);
  AdminDownloadBtn.Width   := ScaleX(220);
  AdminDownloadBtn.Height  := ScaleY(25);
  AdminDownloadBtn.OnClick := @OnAdminDownloadClick;

  // Status label under the button - empty until first click
  AdminDownloadLabel := TNewStaticText.Create(WizardForm);
  AdminDownloadLabel.Parent    := AdminExePage.Surface;
  AdminDownloadLabel.Left      := AdminExePage.Edits[0].Left;
  AdminDownloadLabel.Top       := AdminDownloadBtn.Top + AdminDownloadBtn.Height + ScaleY(8);
  AdminDownloadLabel.AutoSize  := False;
  AdminDownloadLabel.Width     := AdminExePage.SurfaceWidth - AdminExePage.Edits[0].Left;
  AdminDownloadLabel.Height    := ScaleY(36);
  AdminDownloadLabel.WordWrap  := True;
  AdminDownloadLabel.Caption   := '';

  // Page 4: Windows username
  UserPage := CreateInputQueryPage(AdminExePage.ID,
    'Windows Username',
    'What''s your Windows account name?',
    'Used to launch dune-admin under your normal (non-elevated) user account ' +
    'so it can write its own config file.');
  UserPage.Add('Windows username:', False);
  UserPage.Values[0] := defUser;

  // Page 5: port check mode (radio buttons)
  PortModePage := CreateInputOptionPage(UserPage.ID,
    'Port Verification',
    'How should the tool check that your forwarded ports are reachable?',
    'The status header can verify your TCP ports are open from the internet. ' +
    'UDP ports cannot be reliably checked by any free public service - the ' +
    'best UDP test is connecting in-game from a different network.' + #13#10 + #13#10 +
    'You can change this any time by editing %APPDATA%\DuneServer\dune-server.config.',
    True, False);
  PortModePage.Add('Built-in (yougetsignal.com, TCP only) - recommended');
  PortModePage.Add('Custom URL (advanced - you provide a UDP-capable service)');
  PortModePage.Add('Disabled');
  if CompareText(defMode, 'custom')   = 0 then PortModePage.SelectedValueIndex := 1
  else if CompareText(defMode, 'disabled') = 0 then PortModePage.SelectedValueIndex := 2
  else PortModePage.SelectedValueIndex := 0;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if not SkipConfigPages then Exit;
  if (PageID = ServerDirPage.ID) or
     (PageID = SshKeyPage.ID)    or
     (PageID = AdminExePage.ID)  or
     (PageID = UserPage.ID)      or
     (PageID = PortModePage.ID) then
    Result := True;
end;

// ---------- write the config file ----------

procedure WriteDuneConfig();
var
  destDir, dest, portMode, content: string;
begin
  destDir := ExpandConstant('{userappdata}\DuneServer');
  if not DirExists(destDir) then
    ForceDirectories(destDir);
  dest := destDir + '\dune-server.config';

  case PortModePage.SelectedValueIndex of
    1: portMode := 'custom';
    2: portMode := 'disabled';
  else
    portMode := 'builtin';
  end;

  content :=
    '# Dune Awakening Server Management - Configuration' + #13#10 +
    '# Generated by installer on ' + GetDateTimeString('yyyy-mm-dd hh:nn', '-', ':') + #13#10 +
    '# Delete this file to re-run setup from inside the app.' + #13#10 +
    '' + #13#10 +
    'SteamPath='            + ServerDirPage.Values[0] + #13#10 +
    'SshKey='               + SshKeyPage.Values[0]    + #13#10 +
    'DuneAdminExe='         + AdminExePage.Values[0]  + #13#10 +
    'WindowsUser='          + UserPage.Values[0]      + #13#10 +
    'PortCheckMode='        + portMode                + #13#10 +
    'PortCheckUrlTemplate=' + #13#10;

  if SaveStringToFile(dest, content, False) then
    Log('Wrote config: ' + dest)
  else
    Log('FAILED to write config: ' + dest);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if not SkipConfigPages then
      WriteDuneConfig();
  end;
end;
