@echo off
setlocal EnableExtensions

:: ============================================================
:: rippananooru-GPUIP
:: GPU-P + USB/IP Dashboard
:: ============================================================

set "SCRIPT_ROOT=%~dp0"
set "SCRIPT_DIR=%SCRIPT_ROOT%scripts"
set "CONFIG_DIR=%SCRIPT_ROOT%config"

set "GPUP_CONFIG=%CONFIG_DIR%\gpup.xml"
set "USBIP_CONFIG=%CONFIG_DIR%\usbip.xml"

set "GPUP_CONFIG_GENERATOR=%SCRIPT_DIR%\Add-GPUP-Addconfig.ps1"
set "GPUP_ADD=%SCRIPT_DIR%\Add-GPUP.ps1"
set "GPUP_REPAIR=%SCRIPT_DIR%\Repair-GPUP-Code43.ps1"
set "GPUP_STATUS=%SCRIPT_DIR%\Get-GPUPStatus.ps1"

set "USBIP_HOST=%SCRIPT_DIR%\USBIP-HOST.ps1"
set "USBIP_MOUNT=%SCRIPT_DIR%\USBIP-MOUNT.ps1"
set "USBIP_STATUS=%SCRIPT_DIR%\Get-USBIPStatus.ps1"


:: ============================================================
:: ADMIN CHECK
:: ============================================================

net session >nul 2>&1

if errorlevel 1 (
    echo.
    echo ============================================
    echo  Requesting Administrator privileges...
    echo ============================================
    echo.

    powershell.exe -NoProfile -Command ^
        "Start-Process -FilePath '%~f0' -WorkingDirectory 'C:\Windows' -Verb RunAs"

    exit /b
)


:: ============================================================
:: MAIN MENU
:: ============================================================

:MAIN

cls

call :HEADER
call :SHOW_STATUS

echo.
echo ============================================
echo                 MAIN MENU
echo ============================================
echo.
echo [1] Create / Recreate GPU-P Configuration
echo [2] Add GPU-P Partition
echo [3] Repair GPU-P Code 43
echo [4] USB/IP
echo [R] Refresh Status
echo [Q] Exit
echo.

choice /c 1234RQ /n /m "Select: "

if errorlevel 6 goto EXIT
if errorlevel 5 goto MAIN
if errorlevel 4 goto USBIP_MENU
if errorlevel 3 goto REPAIR_GPU
if errorlevel 2 goto ADD_GPU
if errorlevel 1 goto CREATE_CONFIG


:: ============================================================
:: CREATE / RECREATE GPU-P CONFIG
:: ============================================================

:CREATE_CONFIG

cls

call :HEADER

echo.
echo ============================================
echo       CREATE / RECREATE GPU-P CONFIG
echo ============================================
echo.

if not exist "%GPUP_CONFIG_GENERATOR%" (
    echo [ERROR] GPU-P configuration generator not found:
    echo         %GPUP_CONFIG_GENERATOR%
    echo.
    pause
    goto MAIN
)

echo This will create/recreate:
echo.
echo     config\gpup.xml
echo.
echo The configuration contains:
echo     - VM name
echo     - VHDX path
echo     - GPU vendor
echo     - GPU-P partition settings
echo.
echo GPU vendor will be detected automatically.
echo.
echo ============================================
echo.

set "VM_NAME="
set "VHDX_PATH="

set /p "VM_NAME=Enter Hyper-V VM name: "

if not defined VM_NAME (
    echo.
    echo [ERROR] VM name cannot be blank.
    echo.
    pause
    goto MAIN
)

echo.

set /p "VHDX_PATH=Enter VM VHDX path: "

if not defined VHDX_PATH (
    echo.
    echo [ERROR] VHDX path cannot be blank.
    echo.
    pause
    goto MAIN
)

echo.
echo --------------------------------------------
echo Configuration
echo --------------------------------------------
echo VM Name : %VM_NAME%
echo VHDX    : %VHDX_PATH%
echo GPU     : Auto-detected
echo --------------------------------------------
echo.

choice /c YN /n /m "Create this configuration? [Y/N]: "

if errorlevel 2 goto MAIN

echo.
echo Running GPU-P configuration generator...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%GPUP_CONFIG_GENERATOR%" ^
    -VMName "%VM_NAME%" ^
    -VHDXPath "%VHDX_PATH%"

set "EXITCODE=%ERRORLEVEL%"

echo.

if "%EXITCODE%"=="0" (

    if exist "%GPUP_CONFIG%" (
        echo [OK] GPU-P configuration created:
        echo      %GPUP_CONFIG%
    ) else (
        echo [ERROR] Generator completed but gpup.xml was not created.
    )

) else (

    echo [ERROR] Generator exited with code %EXITCODE%.

)

echo.
pause

goto MAIN


:: ============================================================
:: ADD GPU-P PARTITION
:: ============================================================

:ADD_GPU

cls

call :HEADER

echo.
echo ============================================
echo             ADD GPU-P PARTITION
echo ============================================
echo.

if not exist "%GPUP_CONFIG%" (
    echo [ERROR] gpup.xml does not exist.
    echo.
    echo Run option [1] first.
    echo.
    pause
    goto MAIN
)

if not exist "%GPUP_ADD%" (
    echo [ERROR] Add-GPUP.ps1 not found:
    echo         %GPUP_ADD%
    echo.
    pause
    goto MAIN
)

echo Running GPU-P configuration...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%GPUP_ADD%"

set "EXITCODE=%ERRORLEVEL%"

echo.
echo ============================================
echo PowerShell exited with code: %EXITCODE%
echo ============================================
echo.

pause

goto MAIN


:: ============================================================
:: REPAIR GPU-P CODE 43
:: ============================================================

:REPAIR_GPU

cls

call :HEADER

echo.
echo ============================================
echo          REPAIR GPU-P CODE 43
echo ============================================
echo.

if not exist "%GPUP_CONFIG%" (
    echo [ERROR] gpup.xml does not exist.
    echo.
    echo Run option [1] first.
    echo.
    pause
    goto MAIN
)

if not exist "%GPUP_REPAIR%" (
    echo [ERROR] Repair script not found:
    echo         %GPUP_REPAIR%
    echo.
    pause
    goto MAIN
)

echo Running GPU-P Code 43 repair...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%GPUP_REPAIR%"

set "EXITCODE=%ERRORLEVEL%"

echo.
echo ============================================
echo PowerShell exited with code: %EXITCODE%
echo ============================================
echo.

pause

goto MAIN

:: ============================================================
:: USB/IP MENU
:: ============================================================

:USBIP_MENU

cls

call :HEADER

call :SHOW_USBIP_STATUS

echo.

echo ============================================
echo                 USB/IP MENU
echo ============================================
echo.
echo [1] Host   - Share
echo [2] Host   - Unshare
echo [3] Client - Mount
echo [4] Client - Unmount
echo [R] Refresh
echo [B] Back
echo.

choice /c 1234RB /n /m "Select: "

if errorlevel 6 goto MAIN
if errorlevel 5 goto USBIP_MENU
if errorlevel 4 goto USBIP_CLIENT_UNMOUNT
if errorlevel 3 goto USBIP_CLIENT_MOUNT
if errorlevel 2 goto USBIP_HOST_UNSHARE
if errorlevel 1 goto USBIP_HOST_SHARE


:: ============================================================
:: USB/IP HOST - SHARE
:: ============================================================

:USBIP_HOST_SHARE

cls

call :HEADER

echo.

echo ============================================
echo             USB/IP HOST - SHARE
echo ============================================
echo.

if not exist "%USBIP_HOST%" (

    echo [ERROR] USB/IP host script not found:
    echo         %USBIP_HOST%
    echo.

    pause

    goto USBIP_MENU
)

echo Running USB/IP host share...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%USBIP_HOST%" -Action Share

set "EXITCODE=%ERRORLEVEL%"

echo.

echo ============================================
echo PowerShell exited with code: %EXITCODE%
echo ============================================
echo.

pause

goto USBIP_MENU


:: ============================================================
:: USB/IP HOST - UNSHARE
:: ============================================================

:USBIP_HOST_UNSHARE

cls

call :HEADER

echo.

echo ============================================
echo            USB/IP HOST - UNSHARE
echo ============================================
echo.

if not exist "%USBIP_HOST%" (

    echo [ERROR] USB/IP host script not found:
    echo         %USBIP_HOST%
    echo.

    pause

    goto USBIP_MENU
)

echo Running USB/IP host unshare...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%USBIP_HOST%" -Action Unshare

set "EXITCODE=%ERRORLEVEL%"

echo.

echo ============================================
echo PowerShell exited with code: %EXITCODE%
echo ============================================
echo.

pause

goto USBIP_MENU


:: ============================================================
:: USB/IP CLIENT - MOUNT
:: ============================================================

:USBIP_CLIENT_MOUNT

cls

call :HEADER

echo.

echo ============================================
echo            USB/IP CLIENT - MOUNT
echo ============================================
echo.

if not exist "%USBIP_MOUNT%" (

    echo [ERROR] USB/IP mount script not found:
    echo         %USBIP_MOUNT%
    echo.

    pause

    goto USBIP_MENU
)

if not exist "%USBIP_CONFIG%" (

    echo [ERROR] usbip.xml does not exist.
    echo.
    echo No active USB/IP host configuration was found.
    echo.

    pause

    goto USBIP_MENU
)

echo Running USB/IP client mount...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%USBIP_MOUNT%" -Action Mount

set "EXITCODE=%ERRORLEVEL%"

echo.

echo ============================================
echo PowerShell exited with code: %EXITCODE%
echo ============================================
echo.

pause

goto USBIP_MENU


:: ============================================================
:: USB/IP CLIENT - UNMOUNT
:: ============================================================

:USBIP_CLIENT_UNMOUNT

cls

call :HEADER

echo.

echo ============================================
echo           USB/IP CLIENT - UNMOUNT
echo ============================================
echo.

if not exist "%USBIP_MOUNT%" (

    echo [ERROR] USB/IP mount script not found:
    echo         %USBIP_MOUNT%
    echo.

    pause

    goto USBIP_MENU
)

echo Running USB/IP client unmount...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%USBIP_MOUNT%" -Action Unmount

set "EXITCODE=%ERRORLEVEL%"

echo.

echo ============================================
echo PowerShell exited with code: %EXITCODE%
echo ============================================
echo.

pause

goto USBIP_MENU


:: ============================================================
:: HEADER
:: ============================================================

:HEADER

echo.

echo ============================================================
echo              rippananooru-GPUIP DASHBOARD
echo                GPU-P + USB/IP CONTROL
echo ============================================================

exit /b


:: ============================================================
:: MAIN STATUS
:: ============================================================

:SHOW_STATUS

echo.

echo ------------------------------------------------------------
echo SYSTEM
echo ------------------------------------------------------------

if not exist "%GPUP_CONFIG%" (

    echo [--]   GPU-P configuration not created
    echo [--]   VM information unavailable

    goto SHOW_STATUS_USBIP
)

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -Command ^
    "$ErrorActionPreference='SilentlyContinue'; " ^
    "[xml]$c=Get-Content -Raw '%GPUP_CONFIG%'; " ^
    "$vmName=([string]$c.GPUP.VMName).Trim(); " ^
    "$vhdx=([string]$c.GPUP.VHDXPath).Trim(); " ^
    "$gpuVendor=([string]$c.GPUP.GPUVendor).Trim(); " ^
    "if([string]::IsNullOrWhiteSpace($vmName)){Write-Host '[ERROR] VMName missing from gpup.xml'; exit}; " ^
    "if([string]::IsNullOrWhiteSpace($gpuVendor)){Write-Host '[ERROR] GPUVendor missing from gpup.xml'}else{Write-Host ('[OK]   GPU Vendor: '+$gpuVendor)}; " ^
    "$vm=Get-VM -Name $vmName -ErrorAction SilentlyContinue; " ^
    "if($vm){ " ^
        "Write-Host '[OK]   Hyper-V'; " ^
        "Write-Host ('[OK]   VM: '+$vm.Name); " ^
        "if([string]::IsNullOrWhiteSpace($vhdx)){ " ^
            "Write-Host '[ERROR] VHDXPath missing from gpup.xml' " ^
        "}elseif(Test-Path -LiteralPath $vhdx){ " ^
            "$sizeGB=(Get-Item -LiteralPath $vhdx).Length/1GB; " ^
            "Write-Host ('[OK]   VHDXPath: '+$vhdx+' ('+('{0:N0}' -f $sizeGB)+' GB)') " ^
        "}else{ " ^
            "Write-Host ('[ERROR] VHDXPath: '+$vhdx+' (not found)') " ^
        "}; " ^
        "Write-Host ('[OK]   State: '+$vm.State) " ^
    "}else{ " ^
        "Write-Host '[OK]   Hyper-V'; " ^
        "Write-Host ('[ERROR] VM not found: '+$vmName); " ^
        "if(-not [string]::IsNullOrWhiteSpace($vhdx)){ " ^
            "if(Test-Path -LiteralPath $vhdx){ " ^
                "$sizeGB=(Get-Item -LiteralPath $vhdx).Length/1GB; " ^
                "Write-Host ('[OK]   VHDXPath: '+$vhdx+' ('+('{0:N0}' -f $sizeGB)+' GB)') " ^
            "}else{ " ^
                "Write-Host ('[ERROR] VHDXPath: '+$vhdx+' (not found)') " ^
            "} " ^
        "} " ^
    "}"

echo.

echo ------------------------------------------------------------
echo GPU-P
echo ------------------------------------------------------------

if exist "%GPUP_CONFIG%" (

    echo [OK]   Configuration: gpup.xml

) else (

    echo [--]   Configuration: gpup.xml missing
)

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -Command ^
    "$g=Get-VMHostPartitionableGpu -ErrorAction SilentlyContinue; if($g){Write-Host '[OK]   Partitionable GPU detected'}else{Write-Host '[ERROR] No partitionable GPU detected'}"

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -Command ^
    "if(Test-Path '%GPUP_CONFIG%'){[xml]$c=Get-Content -Raw '%GPUP_CONFIG%';$vmName=([string]$c.GPUP.VMName).Trim();$a=Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue;if($a){Write-Host '[OK]   GPU-P adapter installed'}else{Write-Host '[--]   GPU-P adapter not installed'}}"

goto SHOW_STATUS_USBIP


:: ============================================================
:: USB/IP STATUS
:: ============================================================

:SHOW_STATUS_USBIP

echo.

echo ------------------------------------------------------------
echo USB/IP
echo ------------------------------------------------------------

if exist "%USBIP_CONFIG%" (

    echo [OK]   Configuration: usbip.xml

) else (

    echo [--]   Configuration: usbip.xml missing
)

if not exist "%USBIP_STATUS%" (

    echo [--]   Status script not found

    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -File "%USBIP_STATUS%"

exit /b

:: ============================================================
:: SHOW USB/IP STATUS
:: ============================================================

:SHOW_USBIP_STATUS

echo.
echo USB/IP
echo ------------------------------------------------------------

if not exist "%USBIP_CONFIG%" (
    echo [--]   Configuration: usbip.xml missing
    goto :eof
)

echo [OK]   Configuration: usbip.xml

for /f "usebackq delims=" %%A in (`powershell.exe -NoProfile -Command ^
    "$x=[xml](Get-Content -LiteralPath '%USBIP_CONFIG%' -Raw); if($x.USBIP.Host.Name){$x.USBIP.Host.Name}"`) do (
    echo [OK]   Host: %%A
)

for /f "usebackq delims=" %%A in (`powershell.exe -NoProfile -Command ^
    "$x=[xml](Get-Content -LiteralPath '%USBIP_CONFIG%' -Raw); if($x.USBIP.Host.TailscaleIP){$x.USBIP.Host.TailscaleIP}"`) do (
    echo [OK]   Tailscale: %%A
)

for /f "usebackq delims=" %%A in (`powershell.exe -NoProfile -Command ^
    "$x=[xml](Get-Content -LiteralPath '%USBIP_CONFIG%' -Raw); if($x.USBIP.Host.Port){$x.USBIP.Host.Port}"`) do (
    echo [OK]   Port: %%A
)

echo.

echo Shared Devices:
echo.

powershell.exe -NoProfile -Command ^
    "$x=[xml](Get-Content -LiteralPath '%USBIP_CONFIG%' -Raw); $d=@($x.USBIP.Host.Devices.Device); if($d.Count -eq 0){Write-Host '  [--] None'} else {foreach($i in $d){Write-Host ('  [OK]   {0}  {1}  {2}' -f $i.BusID,$i.VIDPID,$i.Name)}}"

goto :eof


:: ============================================================
:: EXIT
:: ============================================================

:EXIT

echo.

echo Exiting rippananooru-GPUIP dashboard...

echo.

exit /b 0