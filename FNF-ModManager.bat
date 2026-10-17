@echo off
rem FNF Mod Manager launcher - runs FNF-ModManager.ps1 with ExecutionPolicy Bypass
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0FNF-ModManager.ps1"
exit /b
