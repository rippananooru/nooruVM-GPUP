@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0USBIP-MOUNT.ps1"
exit /b %ERRORLEVEL%