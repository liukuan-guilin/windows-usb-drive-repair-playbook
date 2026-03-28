@echo off
setlocal
chcp 65001 >nul
set SCRIPT=%~dp0scripts\Repair-Usb-Format-Prompt.ps1
powershell.exe -NoLogo -ExecutionPolicy Bypass -File "%SCRIPT%"
endlocal
