@echo off
setlocal

set "SHORTCUT=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\fakeviewport-win.lnk"

if exist "%SHORTCUT%" (
  del "%SHORTCUT%"
  echo Removed startup shortcut:
  echo "%SHORTCUT%"
) else (
  echo Startup shortcut was not installed.
)
