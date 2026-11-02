@echo off
rem Shizuko launcher (Windows PowerShell 5.1, STA)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Shizuko.ps1"
if errorlevel 1 (
  echo.
  echo Shizuko failed to start. See the error above.
  pause
)
