# ============================================================
# USBIP-MOUNT.ps1
#
# USB/IP CLIENT
#
# - Automatically installs usbip-win2 if missing
# - Reads the active USB/IP host from config\usbip-host.xml
# - Discovers exported USB devices
# - Lets the user select devices by number
# - Attaches devices to this machine
# - Can attach multiple devices
# - Does NOT modify usbip-host.xml
# ============================================================

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS / SETTINGS
# ============================================================

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptRoot "config\usbip-host.xml"
$Port = 3240

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Pause-Script {
    Write-Host ""
    Read-Host "Press Enter to close"
}

function Find-UsbIp {

    # Check PATH first
    $cmd = Get-Command "usbip.exe" -ErrorAction SilentlyContinue

    if ($cmd) {
        return $cmd.Source
    }

    # usbip-win2 0.9.7.8 default installation path
    $Candidates = @(
        "$env:ProgramFiles\USBip\usbip.exe",
        "$env:ProgramFiles\USBip\bin\usbip.exe",
        "${env:ProgramFiles(x86)}\USBip\usbip.exe",
        "${env:ProgramFiles(x86)}\USBip\bin\usbip.exe"
    )

    foreach ($Path in $Candidates) {
        if (Test-Path -LiteralPath $Path) {
            return $Path
        }
    }

    return $null
}

function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Restart-AsAdministrator {
    Write-Host ""
    Write-Host "Administrator privileges are required." -ForegroundColor Yellow
    Write-Host "Restarting USB/IP Mount as Administrator..." -ForegroundColor Yellow
    Write-Host ""

    $Arguments = @(
        "-NoProfile"
        "-ExecutionPolicy Bypass"
        "-File `"$PSCommandPath`""
    )

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList $Arguments

    exit
}

function Install-UsbIpClient {

    Write-Host ""
    Write-Host "USB/IP client was not found." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Package: vadimgrn.usbip-win2"
    Write-Host ""

    $Answer = Read-Host "Install USB/IP client now? [Y/N]"

    if ($Answer -notmatch "^[Yy]$") {
        throw "USB/IP client installation cancelled."
    }

    # Check WinGet
    $Winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue

    if (-not $Winget) {
        throw "WinGet was not found. Install/update App Installer, then run USBIP-MOUNT.cmd again."
    }

    Write-Host ""
    Write-Host "Installing usbip-win2..." -ForegroundColor Cyan
    Write-Host ""

    & $Winget.Source install `
        --exact `
        --id "vadimgrn.usbip-win2" `
        --accept-package-agreements `
        --accept-source-agreements

    if ($LASTEXITCODE -ne 0) {
        throw "usbip-win2 installation failed. WinGet exit code: $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host "USB/IP client installation completed." -ForegroundColor Green

    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable(
        "Path",
        "Machine"
    ) + ";" + [System.Environment]::GetEnvironmentVariable(
        "Path",
        "User"
    )

    Start-Sleep -Seconds 2
}

function Load-HostConfig {

    if (-not (Test-Path $ConfigFile)) {
        throw "USB/IP host registry was not found:`n$ConfigFile"
    }

    try {
        [xml]$Xml = Get-Content -Path $ConfigFile -Raw
    }
    catch {
        throw "Unable to read USB/IP host registry:`n$($_.Exception.Message)"
    }

    return $Xml
}

function Get-HostInformation {

    $Xml = Load-HostConfig

    $HostNode = $Xml.USBIP.Host

    if (-not $HostNode) {
        throw "USB/IP host registry is empty."
    }

    $HostName = [string]$HostNode.Name
    $HostIP   = [string]$HostNode.TailscaleIP
    $HostPort = [int]$HostNode.Port

    if ([string]::IsNullOrWhiteSpace($HostIP)) {
        throw "USB/IP host registry does not contain a Tailscale IP."
    }

    if ($HostPort -le 0) {
        $HostPort = $Port
    }

    return [PSCustomObject]@{
        Name = $HostName
        IP   = $HostIP
        Port = $HostPort
    }
}

function Get-UsbIpDevices {

    param(
        [Parameter(Mandatory)]
        [string]$UsbIpPath,

        [Parameter(Mandatory)]
        [string]$HostIP
    )

    Write-Host ""
    Write-Host "Querying USB/IP host..." -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Host: $HostIP"
    Write-Host "Port: $Port"
    Write-Host ""

    $Output = @(
        & $UsbIpPath list -r $HostIP 2>&1
    )

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host "usbip list returned an error:" -ForegroundColor Red

        $Output | ForEach-Object {
            Write-Host $_
        }

        throw "Unable to query USB/IP host."
    }

    $Devices = @()

    foreach ($LineObject in $Output) {

        $Line = [string]$LineObject

        # ----------------------------------------------------
        # usbip-win2 0.9.7.8 format:
        #
        #    10-4    : Razer USA, Ltd : unknown product (1532:009c)
        #
        # ----------------------------------------------------

        $Match = [regex]::Match(
            $Line,
            '^\s*(?<bus>\S+)\s*:\s*(?<vendor>.*?)\s*:\s*(?<name>.*?)\s*\((?<vidpid>[0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)\s*$'
        )

        if ($Match.Success) {

            $Vendor = $Match.Groups["vendor"].Value.Trim()
            $Name   = $Match.Groups["name"].Value.Trim()
            $VIDPID = $Match.Groups["vidpid"].Value.ToLower()
            $BusID  = $Match.Groups["bus"].Value.Trim()

            # Create a cleaner display name
            if (
                [string]::IsNullOrWhiteSpace($Name) -or
                $Name -eq "unknown product"
            ) {
                $DisplayName = "$Vendor ($VIDPID)"
            }
            else {
                $DisplayName = "$Vendor - $Name"
            }

            $Devices += [PSCustomObject]@{
                BusID  = $BusID
                VIDPID = $VIDPID
                Name   = $DisplayName
            }

            continue
        }
    }

    return $Devices
}

function Show-Devices {

    param(
        [Parameter(Mandatory)]
        [array]$Devices
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "       EXPORTED USB DEVICES" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $Devices.Count; $i++) {

        $Number = $i + 1
        $Device = $Devices[$i]

        Write-Host "[$Number] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($Device.Name)" -ForegroundColor White
        Write-Host "    Bus ID : $($Device.BusID)"
        Write-Host "    VID:PID: $($Device.VIDPID)"
        Write-Host ""
    }
}

function Attach-UsbDevice {

    param(
        [Parameter(Mandatory)]
        [string]$UsbIpPath,

        [Parameter(Mandatory)]
        [string]$HostIP,

        [Parameter(Mandatory)]
        [string]$BusID
    )

    Write-Host ""
    Write-Host "Attaching device..." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Host : $HostIP"
    Write-Host "Bus  : $BusID"
    Write-Host ""

    & $UsbIpPath attach -r $HostIP -b $BusID 2>&1

    $ExitCode = $LASTEXITCODE

    Write-Host ""

    if ($ExitCode -eq 0) {
        Write-Host "USB device attached successfully." -ForegroundColor Green
        return $true
    }

    Write-Host "USB/IP attach failed." -ForegroundColor Red
    Write-Host "Exit code: $ExitCode" -ForegroundColor Red

    return $false
}

# ============================================================
# MAIN
# ============================================================

try {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "       USB/IP MOUNT SCRIPT STARTED" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Script:"
    Write-Host $PSCommandPath

    Write-Host ""
    Write-Host "PowerShell:"
    Write-Host $PSVersionTable.PSVersion

    Write-Host ""
    Write-Host "Working directory:"
    Write-Host $ScriptRoot

    Write-Host ""
    Write-Host "Checking administrator privileges..."

    # --------------------------------------------------------
    # USB/IP driver installation requires Administrator.
    # --------------------------------------------------------

    if (-not (Test-Administrator)) {
        Restart-AsAdministrator
    }

    Write-Host "Administrator: OK" -ForegroundColor Green

    # --------------------------------------------------------
    # Locate USB/IP executable
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Checking usbip.exe..."

    $UsbIpPath = Find-UsbIp

    if (-not $UsbIpPath) {

        Write-Host "usbip.exe was not found." -ForegroundColor Yellow

        Install-UsbIpClient

        $UsbIpPath = Find-UsbIp
    }

    if (-not $UsbIpPath) {

        Write-Host ""
        Write-Host "usbip.exe is still not available." -ForegroundColor Red
        Write-Host ""
        Write-Host "The USB/IP driver may require a Windows restart after installation."
        Write-Host "Restart Windows, then run USBIP-MOUNT.cmd again."

        throw "usbip.exe not found after installation."
    }

    Write-Host "USB/IP client:" -ForegroundColor Green
    Write-Host $UsbIpPath

    # --------------------------------------------------------
    # Test usbip
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Testing USB/IP client..."

    & $UsbIpPath --version 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Warning: usbip.exe --version returned code $LASTEXITCODE" -ForegroundColor Yellow
    }
    else {
        Write-Host "USB/IP client test: OK" -ForegroundColor Green
    }

    # --------------------------------------------------------
    # Read active USB/IP host
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Reading USB/IP host registry..."

    $HostInfo = Get-HostInformation

    Write-Host ""
    Write-Host "Active USB/IP host:" -ForegroundColor Green
    Write-Host "Name : $($HostInfo.Name)"
    Write-Host "IP   : $($HostInfo.IP)"
    Write-Host "Port : $($HostInfo.Port)"

    # --------------------------------------------------------
    # Test TCP connectivity
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Testing TCP port $($HostInfo.Port)..."

    $TcpTest = Test-NetConnection `
        -ComputerName $HostInfo.IP `
        -Port $HostInfo.Port `
        -WarningAction SilentlyContinue

    if (-not $TcpTest.TcpTestSucceeded) {

        Write-Host ""
        Write-Host "Unable to connect to USB/IP host." -ForegroundColor Red
        Write-Host ""
        Write-Host "Host : $($HostInfo.IP)"
        Write-Host "Port : $($HostInfo.Port)"
        Write-Host ""

        throw "TCP connection to USB/IP host failed."
    }

    Write-Host "TCP connection: OK" -ForegroundColor Green

    # --------------------------------------------------------
    # Main attach loop
    # --------------------------------------------------------

    while ($true) {

        $Devices = @(
            Get-UsbIpDevices `
                -UsbIpPath $UsbIpPath `
                -HostIP $HostInfo.IP
        )

        if (-not $Devices -or $Devices.Count -eq 0) {

            Write-Host ""
            Write-Host "No exported USB devices were found." -ForegroundColor Yellow
            Write-Host ""

            # Show raw discovery output once for troubleshooting
            Write-Host "The USB/IP host may currently have no exported devices." -ForegroundColor Yellow

            break
        }

        Show-Devices -Devices $Devices

        Write-Host "Enter the number of the device to attach."
        Write-Host "Enter Q to quit."
        Write-Host ""

        $Selection = Read-Host "Selection"

        if ($Selection -match "^[Qq]$") {
            break
        }

        if ($Selection -notmatch '^\d+$') {

            Write-Host ""
            Write-Host "Invalid selection. Enter a device number." -ForegroundColor Red
            continue
        }

        $SelectedNumber = [int]$Selection

        if ($SelectedNumber -lt 1 -or $SelectedNumber -gt $Devices.Count) {

            Write-Host ""
            Write-Host "Invalid device number." -ForegroundColor Red
            continue
        }

        $SelectedDevice = $Devices[$SelectedNumber - 1]

        Write-Host ""
        Write-Host "Selected device:" -ForegroundColor Cyan
        Write-Host "Name : $($SelectedDevice.Name)"
        Write-Host "Bus  : $($SelectedDevice.BusID)"
        Write-Host "VID  : $($SelectedDevice.VIDPID)"
        Write-Host ""

        $Confirm = Read-Host "Attach this device? [Y/N]"

        if ($Confirm -notmatch "^[Yy]$") {
            continue
        }

        $Attached = Attach-UsbDevice `
            -UsbIpPath $UsbIpPath `
            -HostIP $HostInfo.IP `
            -BusID $SelectedDevice.BusID

        if ($Attached) {

            Write-Host ""
            $Again = Read-Host "Attach another USB device? [Y/N]"

            if ($Again -notmatch "^[Yy]$") {
                break
            }
        }
        else {

            Write-Host ""
            $Again = Read-Host "Try another device? [Y/N]"

            if ($Again -notmatch "^[Yy]$") {
                break
            }
        }
    }

    # ========================================================
    # NORMAL EXIT
    # ========================================================

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "       USB/IP MOUNT FINISHED" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

}
catch {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "       USB/IP MOUNT ERROR" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""

    Write-Host $_.Exception.Message -ForegroundColor Red

    Write-Host ""
    Write-Host "Location:" -ForegroundColor DarkGray
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray

    Write-Host ""
}
finally {

    Write-Host ""
    Read-Host "Press Enter to close"
}