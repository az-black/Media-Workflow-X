; Media Workflow X - Full Windows Installer Script (Inno Setup 6)

#define MyAppName "Media Workflow X"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Media Workflow X"
#define MyAppExeName "MediaWorkflowX.exe"
#define ReleaseDir "c:\projects\app_pengompres_gambar_pdf\frontend_desktop\build\windows\x64\runner\Release"
#define IconPath "c:\projects\app_pengompres_gambar_pdf\frontend_desktop\windows\runner\resources\app_icon.ico"

[Setup]
AppId={{B4E7E4C9-3F61-4B88-9A1D-8E7F5D2A1026}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=c:\projects\app_pengompres_gambar_pdf\installer\output
OutputBaseFilename=MediaWorkflowX_Setup_v{#MyAppVersion}
SetupIconFile={#IconPath}
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
CloseApplications=yes
CloseApplicationsFilter=MediaWorkflowX.exe,smart_compress_backend.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Excludes: "*\CMakeFiles\*,*CMakeCache.txt,*Makefile,*cmake_install.cmake,*.gitkeep"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/F /IM MediaWorkflowX.exe /IM smart_compress_backend.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(200);
  Result := '';
end;
