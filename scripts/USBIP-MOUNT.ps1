# ============================================================
# USBIP-MOUNT.ps1
#
# USB/IP CLIENT - MOUNT / UNMOUNT
#
# Client:
#   vadimgrn.usbip-win2 0.9.7.8
#
# This script is CLIENT ONLY.
# It never exports/binds USB devices.
# ============================================================

param(
    [ValidateSet("Mount", "Unmount")]
    [string]$Action = "Mount"
)

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$ScriptRoot = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $ScriptRoot "config\usbip.xml"

# STRICT Win2 executable
$UsbIpPath = "C:\Program Files\USBip\usbip.exe"

$ExpectedVersion = "0.9.7.8"
$ExpectedPackage = "vadimgrn.usbip-win2"

# ============================================================
# HEADER
# ============================================================

function Write-Header {
    param([string]$Title)

    Write-Host ""
    Write-Host "========================================"
    Write-Host ("       {0}" -f $Title)
    Write-Host "========================================"
    Write-Host ""
}

# ============================================================
# VERIFY WIN2
# ============================================================

function Test-UsbIpWin2 {

    Write-Host "USB/IP client: $UsbIpPath"
    Write-Host ""

    if (-not (Test-Path -LiteralPath $UsbIpPath)) {
        throw "Win2 executable not found: $UsbIpPath"
    }

    $VersionInfo = (Get-Item -LiteralPath $UsbIpPath).VersionInfo
    $ProductVersion = $VersionInfo.ProductVersion

    if ($ProductVersion -ne $ExpectedVersion) {
        throw @"
Wrong USB/IP client version.

Expected : $ExpectedVersion
Found    : $ProductVersion
Path     : $UsbIpPath
"@
    }

    $ReportedVersion = (
        & $UsbIpPath --version 2>&1 |
        Out-String
    ).Trim()

    if ($ReportedVersion -ne $ExpectedVersion) {
        throw @"
USB/IP executable version mismatch.

Expected : $ExpectedVersion
Reported : $ReportedVersion
Path     : $UsbIpPath
"@
    }

    Write-Host "USB/IP client : $ExpectedPackage"
    Write-Host "Version       : $ReportedVersion"
    Write-Host "Executable    : $UsbIpPath"
    Write-Host ""
}

# ============================================================
# LOAD HOST CONFIG
# ============================================================

function Get-HostInfo {

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "USB/IP configuration not found: $ConfigFile"
    }

    [xml]$Config = Get-Content -LiteralPath $ConfigFile -Raw

    $HostIP = $Config.USBIP.Host.TailscaleIP

    if ([string]::IsNullOrWhiteSpace($HostIP)) {
        throw "Host.TailscaleIP is missing from usbip.xml"
    }

    $HostPort = $Config.USBIP.Host.Port

    if ([string]::IsNullOrWhiteSpace($HostPort)) {
        $HostPort = 3240
    }

    return [PSCustomObject]@{
        IP   = $HostIP.Trim()
        Port = [int]$HostPort
    }
}

# ============================================================
# REMOTE USB DEVICE DISCOVERY
# ============================================================

function Get-RemoteUsbDevices {
    param(
        [string]$HostIP
    )

    Write-Host "Discovering USB devices from:"
    Write-Host "  Host : $HostIP"
    Write-Host "  Port : 3240"
    Write-Host ""

    # Run ONCE.
    $Output = @(
        & $UsbIpPath list -r $HostIP 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query remote USB devices."
    }

    $Devices = @()

    foreach ($Line in $Output) {

        $Text = $Line.ToString().Trim()

        # Only accept actual USB device lines:
        #
        # 10-1: Logitech, Inc. : unknown product (046d:c266)
        #
        # Must contain:
        #   bus-id
        #   VID:PID
        #
        if ($Text -match '^(\d+-\d+(?:\.\d+)?)\s*:\s*(.*?)\s*\(([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\)\s*$') {

            $Devices += [PSCustomObject]@{
                BusID = $Matches[1]
                Name  = $Matches[2].Trim()
                VID   = $Matches[3].ToLower()
                PID   = $Matches[4].ToLower()
            }
        }
    }

    return $Devices
}

# ============================================================
# LOCAL USB/IP PORTS
# ============================================================

function Get-LocalUsbPorts {

    $Output = @(
        & $UsbIpPath port 2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    return $Output
}

# ============================================================
# MOUNT
# ============================================================

function Invoke-Mount {

    Write-Header "USB/IP CLIENT - MOUNT"

    Write-Host "Config : $ConfigFile"
    Write-Host ""

    Test-UsbIpWin2

    $HostInfo = Get-HostInfo

    Write-Host "Host : $($HostInfo.IP)"
    Write-Host "Port : $($HostInfo.Port)"
    Write-Host ""

    Write-Header "REMOTE USB DEVICES"

    $Devices = @(Get-RemoteUsbDevices -HostIP $HostInfo.IP)

    if ($Devices.Count -eq 0) {
        Write-Host "No remote USB devices found."
        return 1
    }

    for ($i = 0; $i -lt $Devices.Count; $i++) {

        $Device = $Devices[$i]

        Write-Host ("[{0}] {1}" -f ($i + 1), $Device.BusID)
        Write-Host ("    {0}" -f $Device.Name)
        Write-Host ("    VID:PID {0}:{1}" -f $Device.VID, $Device.PID)
        Write-Host ""
    }

    Write-Host "Enter the number of the device to mount."
    Write-Host "Enter Q to cancel."
    Write-Host ""

    $Selection = Read-Host "Selection"

    if ($Selection -match '^[Qq]$') {
        Write-Host "Cancelled."
        return 0
    }

    $Index = 0

    if (-not [int]::TryParse($Selection, [ref]$Index)) {
        Write-Host "Invalid selection."
        return 1
    }

    if ($Index -lt 1 -or $Index -gt $Devices.Count) {
        Write-Host "Invalid selection."
        return 1
    }

    $Device = $Devices[$Index - 1]

    Write-Host ""
    Write-Host "Selected device:"
    Write-Host "Host : $($HostInfo.IP)"
    Write-Host "Port : $($HostInfo.Port)"
    Write-Host "Bus  : $($Device.BusID)"
    Write-Host "Name : $($Device.Name)"
    Write-Host ""

    $Confirm = Read-Host "Mount this device? [Y/N]"

    if ($Confirm -notmatch '^[Yy]$') {
        Write-Host "Cancelled."
        return 0
    }

    Write-Host ""
    Write-Host "Mounting USB device..."
    Write-Host ""
    Write-Host "Client : $ExpectedPackage $ExpectedVersion"
    Write-Host "Host   : $($HostInfo.IP)"
    Write-Host "Bus    : $($Device.BusID)"
    Write-Host ""

    # ========================================================
    # WIN2 CLIENT ATTACH
    #
    # IMPORTANT:
    # This is the correct syntax for your 0.9.7.8 client.
    #
    # attach = CLIENT MOUNT
    # ========================================================

    & $UsbIpPath attach `
        -r $HostInfo.IP `
        -b $Device.BusID

    $ExitCode = $LASTEXITCODE

    Write-Host ""

    if ($ExitCode -ne 0) {

        Write-Host "========================================"
        Write-Host "       USB/IP CLIENT ERROR"
        Write-Host "========================================"
        Write-Host ""
        Write-Host "USB/IP mount failed with exit code $ExitCode."
        Write-Host ""

        return $ExitCode
    }

    Write-Host "========================================"
    Write-Host "       USB/IP MOUNT SUCCESS"
    Write-Host "========================================"
    Write-Host ""

    return 0
}

# ============================================================
# UNMOUNT
# ============================================================

function Invoke-Unmount {

    Write-Header "USB/IP CLIENT - UNMOUNT"

    Test-UsbIpWin2

    Write-Host "Detecting attached USB/IP devices..."
    Write-Host ""

    $Output = @(Get-LocalUsbPorts)

    if ($Output.Count -eq 0) {
        Write-Host "No USB/IP devices detected."
        return 0
    }

    Write-Host ($Output -join "`n")
    Write-Host ""

    $Port = Read-Host "Enter local USB/IP port to detach"

    if ([string]::IsNullOrWhiteSpace($Port)) {
        Write-Host "Cancelled."
        return 0
    }

    Write-Host ""
    Write-Host "Detaching local USB/IP port $Port..."
    Write-Host ""

    & $UsbIpPath detach -p $Port

    $ExitCode = $LASTEXITCODE

    Write-Host ""

    if ($ExitCode -ne 0) {
        Write-Host "USB/IP detach failed with exit code $ExitCode."
        return $ExitCode
    }

    Write-Host "USB/IP device detached successfully."

    return 0
}

# ============================================================
# MAIN
# ============================================================

try {

    if ($Action -eq "Mount") {
        $Result = Invoke-Mount
    }
    else {
        $Result = Invoke-Unmount
    }

    exit $Result
}
catch {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "       USB/IP CLIENT ERROR"
    Write-Host "========================================"
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""

    exit 1
}