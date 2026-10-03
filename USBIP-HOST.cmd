@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0USBIP-HOST.ps1"
exit /b %ERRORLEVEL%