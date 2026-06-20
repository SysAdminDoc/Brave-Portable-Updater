@echo off
REM Brave-Portable-Updater v1.1.0 - update then launch
setlocal
if not defined PORTABLE_ROOT set "PORTABLE_ROOT=C:\brave-portable-work"
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Update-BravePortable.ps1" -PortableRoot "%PORTABLE_ROOT%" -Quiet %*
set EC=%ERRORLEVEL%
if %EC% EQU 0 (
    if exist "%PORTABLE_ROOT%\brave-portable.exe" start "" "%PORTABLE_ROOT%\brave-portable.exe"
)
endlocal & exit /b %EC%
