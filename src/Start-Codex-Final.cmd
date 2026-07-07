@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Codex-Final.ps1" %*
echo.
echo Press any key to close...
pause >nul
