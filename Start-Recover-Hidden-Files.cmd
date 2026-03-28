@echo off
setlocal
chcp 65001 >nul
set SCRIPT=%~dp0scripts\Recover-Hidden-Usb-Files.ps1
powershell.exe -NoLogo -ExecutionPolicy Bypass -File "%SCRIPT%"
endlocal
