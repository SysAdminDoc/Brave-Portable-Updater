@echo off
REM Brave-Portable-Updater v1.1.0 - foreground shim
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Update-BravePortable.ps1" %*
set EC=%ERRORLEVEL%
if not "%EC%"=="0" (
    echo.
    echo Updater exited with code %EC%.
    pause
)
endlocal & exit /b %EC%
