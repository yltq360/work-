@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%mov-to-gif-gui.ps1" %*
exit /b 0
