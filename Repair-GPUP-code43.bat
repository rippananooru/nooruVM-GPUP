@echo off
setlocal

title nooruVM GPU-P Driver Repair

:: Check administrator privileges
net session >nul 2>&1

if %errorlevel% neq 0 (
    echo.
    echo Requesting Administrator privileges...
    echo.
    powershell.exe -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo ============================================
echo  nooruVM GPU-P DRIVER REPAIR
echo ============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-GPUP-code43.ps1"

echo.
echo Script finished.
pause