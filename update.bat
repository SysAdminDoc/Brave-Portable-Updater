@echo off
REM Brave-Portable-Updater v1.1.0 - default launcher (stable channel)
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Update-BravePortable.ps1"
pause
endlocal
