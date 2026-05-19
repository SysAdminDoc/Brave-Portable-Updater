@echo off
REM Brave-Portable-Updater v1.0.0 - update then launch
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Update-BravePortable.ps1" -Quiet
cd /d "%~dp0\.."
if exist "brave-portable.exe" start "" "brave-portable.exe"
endlocal
exit /b 0
