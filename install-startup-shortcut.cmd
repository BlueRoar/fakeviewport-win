@echo off
setlocal

set "APP_DIR=%~dp0"
set "TARGET=%APP_DIR%start-fakeviewport-win.cmd"
set "STARTUP=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
set "SHORTCUT=%STARTUP%\fakeviewport-win.lnk"

if not exist "%TARGET%" (
  echo Launcher not found: "%TARGET%"
  exit /b 1
)

if not exist "%STARTUP%" (
  mkdir "%STARTUP%"
)

if exist "%SHORTCUT%" (
  del "%SHORTCUT%"
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$shell = New-Object -ComObject WScript.Shell; $shortcut = $shell.CreateShortcut('%SHORTCUT%'); $shortcut.TargetPath = '%TARGET%'; $shortcut.WorkingDirectory = '%APP_DIR%'; $shortcut.Description = 'Start fakeviewport-win for UniFi Protect on login'; $shortcut.Save()"

if errorlevel 1 (
  echo Failed to create startup shortcut.
  exit /b 1
)

echo Installed startup shortcut:
echo "%SHORTCUT%"
