#requires -Version 5.1

<#
.SYNOPSIS
    USB/IP client mount and unmount utility.

.DESCRIPTION
    Reads the USB/IP host configuration from:

        config\usbip.xml

    Mount:
        Discovers USB devices published by the configured host
        and attaches one selected device.

    Unmount:
        Discovers locally mounted USB/IP devices
        and detaches one selected device.

    This script does NOT create, modify, or delete usbip.xml.
    usbip.xml is maintained by USBIP-HOST.ps1.

.NOTES
    Client:
        usbip-win2

    Tested package:
        vadimgrn.usbip-win2
#>

param(
    [ValidateSet("Mount", "Unmount")]
    [string]$Action = "Mount"
)

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$ScriptRoot = $PSScriptRoot
$RepoRoot   = Split-Path -Parent $ScriptRoot

$ConfigDirectory = Join-Path $RepoRoot "config"
$ConfigFile      = Join-Path $ConfigDirectory "usbip.xml"

$DefaultPort = 3240
$WingetPackage = "vadimgrn.usbip-win2"

# ============================================================
# DISPLAY
# ============================================================

function Write-Section {
    param(
        [string]$Title
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host ("       {0}" -f $Title)
    Write-Host "========================================"
    Write-Host ""
}

function Write-ErrorSection {
    param(
        [string]$Message
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host "       USB/IP CLIENT ERROR"
    Write-Host "========================================"
    Write-Host ""
    Write-Host $Message
    Write-Host ""
}

# ============================================================
# ADMIN
# ============================================================

function Test-IsAdministrator {

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-IsAdministrator)) {

    Write-Host "Administrator privileges are required."
    Write-Host "Requesting elevation..."
    Write-Host ""

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-Action", $Action
        )

    exit
}

# ============================================================
# USB/IP CLIENT
# ============================================================

function Get-UsbIpPath {

    $Candidates = @(
        "usbip.exe",
        "C:\Program Files\USBip\usbip.exe",
        "C:\Program Files\USBip\bin\usbip.exe",
        "C:\Program Files (x86)\USBip\usbip.exe",
        "C:\Program Files (x86)\USBip\bin\usbip.exe"
    )

    foreach ($Candidate in $Candidates) {

        if ($Candidate -eq "usbip.exe") {

            $Command = Get-Command usbip.exe `
                -ErrorAction SilentlyContinue

            if ($null -ne $Command) {
                return $Command.Source
            }

            continue
        }

        if (Test-Path -LiteralPath $Candidate) {
            return $Candidate
        }
    }

    return $null
}

function Install-UsbIpClient {

    Write-Host "USB/IP client is not installed."
    Write-Host ""
    Write-Host "Installing:"
    Write-Host "  $WingetPackage"
    Write-Host ""

    winget install `
        --id $WingetPackage `
        --exact `
        --accept-source-agreements `
        --accept-package-agreements

    if ($LASTEXITCODE -ne 0) {
        throw "USB/IP client installation failed."
    }
}

$UsbIpPath = Get-UsbIpPath

if ($null -eq $UsbIpPath) {

    Install-UsbIpClient

    $UsbIpPath = Get-UsbIpPath

    if ($null -eq $UsbIpPath) {
        throw "usbip.exe was not found after installation."
    }
}

# ============================================================
# CONFIG
# ============================================================

function Get-HostConfig {

    if (-not (Test-Path -LiteralPath $ConfigFile)) {

        throw @"
USB/IP configuration was not found:

$ConfigFile

Run USB/IP Host - Share first.
"@
    }

    try {
        [xml]$Xml = Get-Content `
            -LiteralPath $ConfigFile `
            -Raw `
            -ErrorAction Stop
    }
    catch {
        throw "Failed to read usbip.xml: $($_.Exception.Message)"
    }

    if ($null -eq $Xml.USBIP) {
        throw "Invalid usbip.xml: missing <USBIP>."
    }

    if ($null -eq $Xml.USBIP.Host) {
        throw "Invalid usbip.xml: missing <Host>."
    }

    return $Xml.USBIP.Host
}

function Get-HostInformation {

    $HostConfig = Get-HostConfig

    $HostName = [string]$HostConfig.Name
    $HostIP   = [string]$HostConfig.TailscaleIP
    $HostPort = [int]$DefaultPort

    if (-not [string]::IsNullOrWhiteSpace(
        [string]$HostConfig.Port
    )) {
        $HostPort = [int]$HostConfig.Port
    }

    if ([string]::IsNullOrWhiteSpace($HostIP)) {
        throw "usbip.xml does not contain Host.TailscaleIP."
    }

    [PSCustomObject]@{
        Name = $HostName
        IP   = $HostIP
        Port = $HostPort
    }
}

# ============================================================
# REMOTE USB DEVICES
# ============================================================

function Get-RemoteUsbDevices {

    param(
        [string]$HostIP,
        [int]$HostPort
    )

    Write-Host "Discovering USB devices from:"
    Write-Host "  Host : $HostIP"
    Write-Host "  Port : $HostPort"
    Write-Host ""

    $Output = @(
        & $UsbIpPath list -r $HostIP 2>&1
    )

    if ($LASTEXITCODE -ne 0) {

        $Text = ($Output | Out-String).Trim()

        if ([string]::IsNullOrWhiteSpace($Text)) {
            $Text = "usbip list failed."
        }

        throw $Text
    }

    $Devices = @()

    foreach ($Line in $Output) {

        $Text = [string]$Line

        # usbip-win2 0.9.7.8 format:
        #
        # 10-4    : Razer USA, Ltd : unknown product (1532:009c)
        #
        # Also supports:
        #
        # 1-3     : Logitech, Inc. : Gaming Mouse (046d:c24f)

        if ($Text -match `
            '^\s*(?<bus>\S+)\s*:\s*(?<vendor>.*?)\s*:\s*(?<name>.*?)\s*\((?<vidpid>[0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)\s*$') {

            $Devices += [PSCustomObject]@{
                BusID  = $Matches.bus
                Vendor = $Matches.vendor.Trim()
                Name   = $Matches.name.Trim()
                VIDPID = $Matches.vidpid.ToLower()
            }
        }
    }

    return @($Devices)
}

# ============================================================
# MOUNT
# ============================================================

function Invoke-Mount {

    Write-Section "USB/IP CLIENT - MOUNT"

    Write-Host "Config : $ConfigFile"
    Write-Host ""
    Write-Host "USB/IP client: $UsbIpPath"

    $HostInfo = Get-HostInformation

    Write-Host ""
    Write-Host "Host : $($HostInfo.Name)"
    Write-Host "IP   : $($HostInfo.IP)"
    Write-Host "Port : $($HostInfo.Port)"

    Write-Section "REMOTE USB DEVICES"

    $Devices = @(Get-RemoteUsbDevices `
        -HostIP $HostInfo.IP `
        -HostPort $HostInfo.Port)

    if ($Devices.Count -eq 0) {

        Write-Host "No USB devices are currently available."
        Write-Host ""
        return
    }

    for ($i = 0; $i -lt $Devices.Count; $i++) {

        $Device = $Devices[$i]

        Write-Host ("[{0}] {1}" -f ($i + 1), $Device.BusID)
        Write-Host ("    {0}" -f $Device.Vendor)
        Write-Host ("    {0}" -f $Device.Name)
        Write-Host ("    VID:PID {0}" -f $Device.VIDPID)
        Write-Host ""
    }

    Write-Host "Enter the number of the device to mount."
    Write-Host "Enter Q to cancel."
    Write-Host ""

    $Selection = Read-Host "Selection"

    if ($Selection -match '^[Qq]$') {
        Write-Host ""
        Write-Host "Cancelled."
        return
    }

    if ($Selection -notmatch '^\d+$') {
        throw "Invalid selection."
    }

    $Index = [int]$Selection - 1

    if ($Index -lt 0 -or $Index -ge $Devices.Count) {
        throw "Invalid device selection."
    }

    $Device = $Devices[$Index]

    Write-Host ""
    Write-Host "Selected device:"
    Write-Host "Host : $($HostInfo.IP)"
    Write-Host "Port : $($HostInfo.Port)"
    Write-Host "Bus  : $($Device.BusID)"
    Write-Host "Name : $($Device.Name)"
    Write-Host ""

    $Confirm = Read-Host "Mount this device? [Y/N]"

    if ($Confirm -notmatch '^[Yy]$') {
        Write-Host ""
        Write-Host "Cancelled."
        return
    }

    Write-Host ""
    Write-Host "Mounting USB device..."
    Write-Host ""
    Write-Host "Host : $($HostInfo.IP)"
    Write-Host "Bus  : $($Device.BusID)"
    Write-Host ""

    & $UsbIpPath attach `
        -r $HostInfo.IP `
        -b $Device.BusID

    $ExitCode = $LASTEXITCODE

    Write-Host ""

    if ($ExitCode -ne 0) {
        throw "USB/IP mount failed with exit code $ExitCode."
    }

    Write-Host "USB device mounted successfully."
}

# ============================================================
# LOCAL USB/IP DEVICES
# ============================================================

function Get-LocalUsbIpDevices {

    $Output = @(
        & $UsbIpPath port 2>&1
    )

    if ($LASTEXITCODE -ne 0) {

        $Text = ($Output | Out-String).Trim()

        if ([string]::IsNullOrWhiteSpace($Text)) {
            $Text = "usbip port failed."
        }

        throw $Text
    }

    $Devices = @()

    $CurrentLocalPort  = $null
    $CurrentHost       = $null
    $CurrentRemotePort = $null
    $CurrentBusID      = $null

    foreach ($Line in $Output) {

        $Text = [string]$Line

        # ----------------------------------------------------
        # Local USB/IP port
        #
        # Actual usbip-win2 0.9.7.8 format:
        #
        # Port 01: device in use at Full Speed(12Mbps)
        # ----------------------------------------------------

        if ($Text -match `
            '^\s*Port\s+(?<port>\d+):') {

            # Flush previous device.
            if ($null -ne $CurrentLocalPort -and
                $null -ne $CurrentHost -and
                $null -ne $CurrentBusID) {

                $Devices += [PSCustomObject]@{
                    LocalPort  = [int]$CurrentLocalPort
                    Host       = $CurrentHost
                    Port       = $CurrentRemotePort
                    BusID      = $CurrentBusID
                }
            }

            $CurrentLocalPort  = [int]$Matches.port
            $CurrentHost       = $null
            $CurrentRemotePort = $null
            $CurrentBusID      = $null

            continue
        }

        # ----------------------------------------------------
        # Remote USB/IP endpoint
        # ----------------------------------------------------

        if ($Text -match `
            'usbip://(?<host>[^/:]+):(?<port>\d+)/(?<bus>\S+)') {

            $CurrentHost       = $Matches.host
            $CurrentRemotePort = [int]$Matches.port
            $CurrentBusID      = $Matches.bus

            continue
        }
    }

    # --------------------------------------------------------
    # Flush final device
    # --------------------------------------------------------

    if ($null -ne $CurrentLocalPort -and
        $null -ne $CurrentHost -and
        $null -ne $CurrentBusID) {

        if ($null -eq $CurrentRemotePort) {
            $CurrentRemotePort = 3240
        }

        $Devices += [PSCustomObject]@{
            LocalPort  = [int]$CurrentLocalPort
            Host       = $CurrentHost
            Port       = $CurrentRemotePort
            BusID      = $CurrentBusID
        }
    }

    return @($Devices)
}
# ============================================================
# UNMOUNT
# ============================================================

function Invoke-Unmount {

    Write-Section "USB/IP CLIENT - UNMOUNT"

    Write-Host "Config : $ConfigFile"
    Write-Host ""
    Write-Host "USB/IP client: $UsbIpPath"

    Write-Section "MOUNTED USB/IP DEVICES"

    $Devices = @(Get-LocalUsbIpDevices)

    if ($Devices.Count -eq 0) {

        Write-Host "No USB/IP devices are currently mounted."
        Write-Host ""
        return
    }

    for ($i = 0; $i -lt $Devices.Count; $i++) {

        $Device = $Devices[$i]

        Write-Host ("[{0}] {1}" -f ($i + 1), $Device.BusID)
        Write-Host ("    Host : {0}" -f $Device.Host)
        Write-Host ("    Port : {0}" -f $Device.Port)
        Write-Host ("    Local USB/IP port : {0}" -f $Device.LocalPort)
        Write-Host ""
    }

    Write-Host "Enter the number of the device to unmount."
    Write-Host "Enter Q to cancel."
    Write-Host ""

    $Selection = Read-Host "Selection"

    if ($Selection -match '^[Qq]$') {
        Write-Host ""
        Write-Host "Cancelled."
        return
    }

    if ($Selection -notmatch '^\d+$') {
        throw "Invalid selection."
    }

    $Index = [int]$Selection - 1

    if ($Index -lt 0 -or $Index -ge $Devices.Count) {
        throw "Invalid device selection."
    }

    $Device = $Devices[$Index]

    Write-Host ""
    Write-Host "Selected device:"
    Write-Host "Host : $($Device.Host)"
    Write-Host "Port : $($Device.Port)"
    Write-Host "Bus  : $($Device.BusID)"
    Write-Host "Local USB/IP port : $($Device.LocalPort)"
    Write-Host ""

    $Confirm = Read-Host "Unmount this device? [Y/N]"

    if ($Confirm -notmatch '^[Yy]$') {
        Write-Host ""
        Write-Host "Cancelled."
        return
    }

    Write-Host ""
    Write-Host "Unmounting USB device..."
    Write-Host ""
    Write-Host "Host : $($Device.Host)"
    Write-Host "Bus  : $($Device.BusID)"
    Write-Host "Local USB/IP port : $($Device.LocalPort)"
    Write-Host ""

    # IMPORTANT:
    # usbip-win2 requires the LOCAL USB/IP port for detach.
    #
    # Correct:
    #     usbip detach -p <local-port>
    #
    # NOT:
    #     usbip detach -r <host> -b <busid>

    & $UsbIpPath detach `
        -p $Device.LocalPort

    $ExitCode = $LASTEXITCODE

    Write-Host ""

    if ($ExitCode -ne 0) {
        throw "USB/IP unmount failed with exit code $ExitCode."
    }

    Write-Host "USB device unmounted successfully."
}

# ============================================================
# MAIN
# ============================================================

try {

    if ($Action -eq "Mount") {
        Invoke-Mount
    }
    elseif ($Action -eq "Unmount") {
        Invoke-Unmount
    }

    exit 0
}
catch {

    Write-ErrorSection $_.Exception.Message

    exit 1
}