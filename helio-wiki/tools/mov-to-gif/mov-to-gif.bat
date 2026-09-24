@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%mov-to-gif.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

if /i not "%MOV_TO_GIF_NO_PAUSE%"=="1" (
    echo.
    echo Press any key to close this window...
    pause >nul
)

exit /b %EXIT_CODE%
