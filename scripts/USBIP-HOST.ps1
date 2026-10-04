# ============================================================
# USBIP-HOST.ps1
#
# USB/IP HOST
#
# Runs on the machine where the physical USB device is connected.
#
# Actions:
#   Share
#   Unshare
#
# Responsibilities:
#   - Ensure usbipd-win is installed
#   - Ensure usbipd service is running
#   - Ensure TCP 3240 is allowed
#   - Show local USB devices
#   - Share / unshare selected devices
#   - Maintain the active USB/IP host XML
#   - Stop Steam for devices that cannot be exported while Steam
#     is actively using them
#
# Runtime XML:
#   config\usbip.xml
#
# ============================================================

param(
    [ValidateSet("Share", "Unshare")]
    [string]$Action = "Share"
)

$ErrorActionPreference = "Stop"

# ============================================================
# REPOSITORY / CONFIGURATION
# ============================================================

$ScriptRoot = $PSScriptRoot
$RepoRoot   = Split-Path -Parent $ScriptRoot

$ConfigDirectory = Join-Path $RepoRoot "config"
$ConfigFile      = Join-Path $ConfigDirectory "usbip.xml"

$Port     = 3240
$RuleName = "USBIP - Allow TCP 3240"

$WingetPackage = "dorssel.usbipd-win"

# ============================================================
# DEVICES THAT REQUIRE STEAM TO BE STOPPED
#
# USB/IP cannot export these devices while Steam is actively
# using them.
#
# Format:
#   VID:PID
#
# Logitech G923:
#   046d:c266
#
# Add future Steam-exclusive devices here if required.
# ============================================================

$SteamExclusiveDevices = @(
    "046d:c266"
)

# ============================================================
# SELF ELEVATE
# ============================================================

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {

    Write-Host ""
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
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
# FUNCTIONS
# ============================================================

function Get-UsbIpdPath {

    $command = Get-Command "usbipd.exe" -ErrorAction SilentlyContinue

    if ($command) {
        return $command.Source
    }

    $paths = @(
        "$env:ProgramFiles\usbipd-win\usbipd.exe",
        "$env:ProgramFiles\usbipd\usbipd.exe",
        "$env:ProgramFiles\USBIPD\usbipd.exe"
    )

    foreach ($path in $paths) {

        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Install-UsbIpd {

    Write-Host ""
    Write-Host "USB/IP host software is not installed." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Package : $WingetPackage"
    Write-Host ""

    $answer = Read-Host "Install USB/IP host now? [Y/N]"

    if ($answer -notmatch '^[Yy]$') {

        Write-Host ""
        Write-Host "USB/IP installation cancelled." -ForegroundColor Yellow
        return $false
    }

    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue

    if (-not $winget) {

        Write-Host ""
        Write-Host "ERROR: winget was not found." -ForegroundColor Red
        Write-Host ""
        Write-Host "Install Microsoft App Installer / WinGet first."
        Write-Host ""

        return $false
    }

    Write-Host ""
    Write-Host "Installing usbipd-win..." -ForegroundColor Cyan
    Write-Host ""

    & $winget.Source install `
        --exact `
        --id $WingetPackage `
        --accept-package-agreements `
        --accept-source-agreements

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host "ERROR: usbipd-win installation failed." -ForegroundColor Red

        return $false
    }

    Write-Host ""
    Write-Host "usbipd-win installation completed." -ForegroundColor Green

    $machinePath = [Environment]::GetEnvironmentVariable(
        "Path",
        "Machine"
    )

    $userPath = [Environment]::GetEnvironmentVariable(
        "Path",
        "User"
    )

    $env:Path = "$machinePath;$userPath"

    return $true
}

function Get-TailscaleIPv4 {

    $tailscale = Get-Command "tailscale.exe" -ErrorAction SilentlyContinue

    if ($tailscale) {

        try {

            $addresses = & $tailscale.Source ip -4 2>$null

            foreach ($address in $addresses) {

                $address = ([string]$address).Trim()

                if ($address -match '^100\.(\d{1,3}\.){2}\d{1,3}$') {
                    return $address
                }
            }
        }
        catch {
        }
    }

    try {

        $addresses = Get-NetIPAddress `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue

        foreach ($address in $addresses) {

            if ($address.IPAddress -match '^100\.(\d{1,3}\.){2}\d{1,3}$') {
                return $address.IPAddress
            }
        }
    }
    catch {
    }

    return $null
}

function Get-UsbIpdList {

    $output = & $UsbIpd list 2>&1

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host "ERROR: usbipd list failed." -ForegroundColor Red

        $output | ForEach-Object {
            Write-Host $_
        }

        return @()
    }

    return @($output)
}

function Parse-UsbIpdDevices {

    param(
        [string[]]$Lines
    )

    $devices = @()

    foreach ($line in $Lines) {

        $text = ([string]$line).TrimEnd()

        if ($text -match '^\s*(\S+)\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+?)\s*$') {

            $busId       = $Matches[1]
            $vidPid      = $Matches[2].ToLower()
            $description = $Matches[3].Trim()

            if ($busId -match '^(BUSID|BUS)$') {
                continue
            }

            $state = ""

            if ($description -match '\b(Not shared|Shared|Attached)\b') {
                $state = $Matches[1]
            }

            $devices += [PSCustomObject]@{
                BusId       = $busId
                VidPid      = $vidPid
                Description = $description
                State       = $state
            }
        }
    }

    return @($devices)
}

function Get-AllDevices {

    return @(
        Parse-UsbIpdDevices `
            -Lines (Get-UsbIpdList)
    )
}

function Get-SharedDevices {

    $devices = Get-AllDevices

    return @(
        $devices | Where-Object {
            $_.State -in @("Shared", "Attached")
        }
    )
}

# ============================================================
# STEAM HANDLING
# ============================================================

function Test-SteamExclusiveDevice {

    param(
        [PSCustomObject]$Device
    )

    if (-not $Device) {
        return $false
    }

    return $SteamExclusiveDevices -contains $Device.VidPid
}

function Stop-SteamForDevice {

    param(
        [PSCustomObject]$Device
    )

    if (-not (Test-SteamExclusiveDevice -Device $Device)) {
        return
    }

    Write-Host ""
    Write-Host "Steam-exclusive device detected." -ForegroundColor Yellow
    Write-Host "VID:PID : $($Device.VidPid)" -ForegroundColor Yellow
    Write-Host "Device  : $($Device.Description)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Stopping Steam before USB/IP sharing..." -ForegroundColor Cyan
    Write-Host ""

    $steamProcesses = @(
        "steam",
        "steamservice",
        "steamwebhelper"
    )

    $found = $false

    foreach ($processName in $steamProcesses) {

        $processes = Get-Process `
            -Name $processName `
            -ErrorAction SilentlyContinue

        if ($processes) {

            $found = $true

            foreach ($process in $processes) {

                Write-Host "Stopping $($process.ProcessName) (PID $($process.Id))..." `
                    -ForegroundColor Yellow

                try {

                    Stop-Process `
                        -Id $process.Id `
                        -Force `
                        -ErrorAction Stop
                }
                catch {

                    Write-Host `
                        "WARNING: Could not stop $($process.ProcessName) (PID $($process.Id))." `
                        -ForegroundColor Yellow
                }
            }
        }
    }

    if (-not $found) {

        Write-Host "Steam is not running." -ForegroundColor Green
    }
    else {

        # Give Steam a moment to release the USB device.
        Start-Sleep -Seconds 2

        Write-Host ""
        Write-Host "Steam stopped. USB device should now be available." `
            -ForegroundColor Green
    }

    Write-Host ""
}

# ============================================================
# XML
# ============================================================

function Publish-ActiveHost {

    param(
        [array]$Devices
    )

    if (-not (Test-Path $ConfigDirectory)) {

        New-Item `
            -ItemType Directory `
            -Path $ConfigDirectory `
            -Force | Out-Null
    }

    # --------------------------------------------------------
    # No shared devices
    # --------------------------------------------------------

    if (-not $Devices -or $Devices.Count -eq 0) {

        if (Test-Path $ConfigFile) {

            Remove-Item `
                -LiteralPath $ConfigFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Write-Host ""
        Write-Host "No USB devices are currently shared." -ForegroundColor Yellow
        Write-Host "usbip.xml removed." -ForegroundColor Yellow

        return $true
    }

    # --------------------------------------------------------
    # Tailscale address
    # --------------------------------------------------------

    $tailscaleIP = Get-TailscaleIPv4

    if (-not $tailscaleIP) {

        Write-Host ""
        Write-Host "ERROR: Tailscale IPv4 address not found." -ForegroundColor Red

        return $false
    }

    # --------------------------------------------------------
    # Create XML
    # --------------------------------------------------------

    $settings = New-Object System.Xml.XmlWriterSettings

    $settings.Indent   = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)

    $writer = [System.Xml.XmlWriter]::Create(
        $ConfigFile,
        $settings
    )

    try {

        $writer.WriteStartDocument()

        $writer.WriteStartElement("USBIP")

        $writer.WriteStartElement("Host")

        $writer.WriteElementString(
            "Name",
            $env:COMPUTERNAME
        )

        $writer.WriteElementString(
            "TailscaleIP",
            $tailscaleIP
        )

        $writer.WriteElementString(
            "Port",
            $Port.ToString()
        )

        $writer.WriteElementString(
            "LastSeen",
            (Get-Date).ToString("o")
        )

        $writer.WriteStartElement("Devices")

        foreach ($device in $Devices) {

            $writer.WriteStartElement("Device")

            $writer.WriteElementString(
                "BusID",
                $device.BusId
            )

            $writer.WriteElementString(
                "VIDPID",
                $device.VidPid
            )

            $writer.WriteElementString(
                "Name",
                $device.Description
            )

            $writer.WriteEndElement()
        }

        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndElement()

        $writer.WriteEndDocument()
    }
    finally {

        $writer.Close()
    }

    Write-Host ""
    Write-Host "USB/IP configuration updated." -ForegroundColor Green
    Write-Host "Config : $ConfigFile" -ForegroundColor Green

    return $true
}

function Refresh-HostXml {

    $shared = Get-SharedDevices

    Publish-ActiveHost -Devices $shared | Out-Null

    return $shared
}

# ============================================================
# DISPLAY
# ============================================================

function Show-Devices {

    param(
        [array]$Devices,
        [string]$Title
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "          $Title" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not $Devices -or $Devices.Count -eq 0) {

        Write-Host "No USB devices found." -ForegroundColor Yellow
        return
    }

    for ($i = 0; $i -lt $Devices.Count; $i++) {

        $device = $Devices[$i]

        $stateColor = "Gray"

        if ($device.State -eq "Shared") {
            $stateColor = "Green"
        }

        Write-Host "[$($i + 1)] $($device.BusId)" -ForegroundColor Yellow
        Write-Host "    VID:PID : $($device.VidPid)"
        Write-Host "    Device  : $($device.Description)"
        Write-Host "    State   : " -NoNewline
        Write-Host "$($device.State)" -ForegroundColor $stateColor
        Write-Host ""
    }
}

function Select-Device {

    param(
        [array]$Devices,
        [string]$Prompt
    )

    while ($true) {

        $selection = Read-Host $Prompt

        if ($selection -match '^[Qq]$') {
            return $null
        }

        $number = 0

        if (
            [int]::TryParse(
                $selection,
                [ref]$number
            ) -and
            $number -ge 1 -and
            $number -le $Devices.Count
        ) {

            return $Devices[$number - 1]
        }

        Write-Host "Invalid selection." -ForegroundColor Red
    }
}

# ============================================================
# COMMON SETUP
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan

if ($Action -eq "Share") {
    Write-Host "          USB/IP HOST - SHARE" -ForegroundColor Cyan
}
else {
    Write-Host "         USB/IP HOST - UNSHARE" -ForegroundColor Cyan
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Config : $ConfigFile" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
# ENSURE USBIPD
# ============================================================

$UsbIpd = Get-UsbIpdPath

if (-not $UsbIpd) {

    if (-not (Install-UsbIpd)) {

        Read-Host "Press Enter to close"
        exit 1
    }

    $UsbIpd = Get-UsbIpdPath
}

if (-not $UsbIpd) {

    Write-Host ""
    Write-Host "ERROR: usbipd.exe is still not available." -ForegroundColor Red
    Write-Host ""
    Write-Host "A restart may be required after installation."
    Write-Host ""

    Read-Host "Press Enter to close"
    exit 1
}

Write-Host "usbipd : $UsbIpd" -ForegroundColor Green

# ============================================================
# ENSURE SERVICE
# ============================================================

$service = Get-Service `
    -Name "usbipd" `
    -ErrorAction SilentlyContinue

if (-not $service) {

    Write-Host ""
    Write-Host "ERROR: usbipd service was not found." -ForegroundColor Red
    Write-Host ""

    Read-Host "Press Enter to close"
    exit 1
}

if ($service.Status -ne "Running") {

    Write-Host ""
    Write-Host "Starting usbipd service..." -ForegroundColor Yellow

    Start-Service usbipd

    Start-Sleep -Seconds 1
}

Write-Host "usbipd service: Running" -ForegroundColor Green

# ============================================================
# FIREWALL
# ============================================================

$rule = Get-NetFirewallRule `
    -DisplayName $RuleName `
    -ErrorAction SilentlyContinue

if (-not $rule) {

    Write-Host ""
    Write-Host "Creating firewall rule..." -ForegroundColor Yellow

    New-NetFirewallRule `
        -DisplayName $RuleName `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $Port `
        -Action Allow `
        -Profile Any `
        -Description "Allow USB/IP clients to connect to usbipd-win on TCP 3240" `
        -ErrorAction Stop | Out-Null

    Write-Host "Firewall rule: Created" -ForegroundColor Green
}
else {

    Write-Host "Firewall rule: Already exists" -ForegroundColor Green
}

# ============================================================
# TAILSCALE
# ============================================================

$tailscaleIP = Get-TailscaleIPv4

if (-not $tailscaleIP) {

    Write-Host ""
    Write-Host "ERROR: Tailscale IPv4 address not found." -ForegroundColor Red
    Write-Host ""

    Read-Host "Press Enter to close"
    exit 1
}

Write-Host "Tailscale : $tailscaleIP" -ForegroundColor Green

# ============================================================
# ACTION: SHARE
# ============================================================

if ($Action -eq "Share") {

    $devices = Get-AllDevices

    if (-not $devices -or $devices.Count -eq 0) {

        Write-Host ""
        Write-Host "No USB devices detected." -ForegroundColor Yellow
        Write-Host ""

        Read-Host "Press Enter to close"
        exit 0
    }

    Show-Devices `
        -Devices $devices `
        -Title "USB/IP HOST - SHARE"

    $selected = Select-Device `
        -Devices $devices `
        -Prompt "Select device number (Q to exit)"

    if (-not $selected) {

        Write-Host ""
        Write-Host "Share cancelled." -ForegroundColor Yellow

        exit 0
    }

    Write-Host ""
    Write-Host "Selected:" -ForegroundColor Green
    Write-Host "  Bus ID : $($selected.BusId)"
    Write-Host "  VID:PID: $($selected.VidPid)"
    Write-Host "  Device : $($selected.Description)"
    Write-Host "  State  : $($selected.State)"
    Write-Host ""

    if ($selected.State -eq "Shared") {

        Write-Host "This device is already shared." -ForegroundColor Yellow
        Write-Host ""

        # Make sure XML is synchronized.
        $shared = Refresh-HostXml

        Write-Host ""
        Write-Host "usbip.xml synchronized." -ForegroundColor Green

        Read-Host "Press Enter to close"
        exit 0
    }

    $confirm = Read-Host "Share this device? [Y/N]"

    if ($confirm -notmatch '^[Yy]$') {

        Write-Host ""
        Write-Host "Share cancelled." -ForegroundColor Yellow

        exit 0
    }

    # --------------------------------------------------------
    # Steam handling
    #
    # Only devices explicitly listed in
    # $SteamExclusiveDevices will trigger this.
    # --------------------------------------------------------

    Stop-SteamForDevice -Device $selected

    # --------------------------------------------------------
    # Bind
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Sharing $($selected.BusId)..." -ForegroundColor Cyan
    Write-Host ""

    & $UsbIpd bind --busid="$($selected.BusId)"

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host "ERROR: Failed to share device." -ForegroundColor Red
        Write-Host ""

        Read-Host "Press Enter to close"
        exit 1
    }

    Write-Host ""
    Write-Host "Device shared successfully." -ForegroundColor Green

    Start-Sleep -Milliseconds 500

    # --------------------------------------------------------
    # Generate / update usbip.xml
    # --------------------------------------------------------

    $shared = Refresh-HostXml

    if (-not (Test-Path $ConfigFile)) {

        Write-Host ""
        Write-Host "ERROR: usbip.xml was not created." -ForegroundColor Red
        Write-Host ""

        Read-Host "Press Enter to close"
        exit 1
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "          USB/IP HOST - SHARE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Host      : $env:COMPUTERNAME"
    Write-Host "Tailscale : $tailscaleIP"
    Write-Host "Port      : $Port"
    Write-Host "Config    : $ConfigFile"
    Write-Host ""
    Write-Host "Shared devices:" -ForegroundColor Cyan

    foreach ($device in $shared) {

        Write-Host "  $($device.BusId)  $($device.VidPid)  $($device.Description)"
    }

    Write-Host ""
    Write-Host "USB/IP host share completed." -ForegroundColor Green
    Write-Host ""

    Read-Host "Press Enter to close"

    exit 0
}

# ============================================================
# ACTION: UNSHARE
# ============================================================

if ($Action -eq "Unshare") {

    $devices = Get-SharedDevices

    if (-not $devices -or $devices.Count -eq 0) {

        Write-Host ""
        Write-Host "No shared USB devices found." -ForegroundColor Yellow
        Write-Host ""

        # Clean stale XML if necessary.
        Refresh-HostXml | Out-Null

        Read-Host "Press Enter to close"
        exit 0
    }

    Show-Devices `
        -Devices $devices `
        -Title "USB/IP HOST - UNSHARE"

    $selected = Select-Device `
        -Devices $devices `
        -Prompt "Select shared device number (Q to exit)"

    if (-not $selected) {

        Write-Host ""
        Write-Host "Unshare cancelled." -ForegroundColor Yellow

        exit 0
    }

    Write-Host ""
    Write-Host "Selected:" -ForegroundColor Green
    Write-Host "  Bus ID : $($selected.BusId)"
    Write-Host "  VID:PID: $($selected.VidPid)"
    Write-Host "  Device : $($selected.Description)"
    Write-Host ""

    $confirm = Read-Host "Unshare this device? [Y/N]"

    if ($confirm -notmatch '^[Yy]$') {

        Write-Host ""
        Write-Host "Unshare cancelled." -ForegroundColor Yellow

        exit 0
    }

    # --------------------------------------------------------
    # Unbind
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Unsharing $($selected.BusId)..." -ForegroundColor Cyan
    Write-Host ""

    & $UsbIpd unbind --busid="$($selected.BusId)"

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host "ERROR: Failed to unshare device." -ForegroundColor Red
        Write-Host ""

        Read-Host "Press Enter to close"
        exit 1
    }

    Write-Host ""
    Write-Host "Device unshared successfully." -ForegroundColor Green

    Start-Sleep -Milliseconds 500

    # --------------------------------------------------------
    # Update / remove usbip.xml
    # --------------------------------------------------------

    $shared = Refresh-HostXml

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "         USB/IP HOST - UNSHARE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    if ($shared -and $shared.Count -gt 0) {

        Write-Host "Remaining shared devices:" -ForegroundColor Cyan

        foreach ($device in $shared) {

            Write-Host "  $($device.BusId)  $($device.VidPid)  $($device.Description)"
        }

        Write-Host ""
        Write-Host "usbip.xml updated." -ForegroundColor Green
    }
    else {

        Write-Host "No USB devices remain shared." -ForegroundColor Yellow
        Write-Host "usbip.xml removed." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "USB/IP host unshare completed." -ForegroundColor Green
    Write-Host ""

    Read-Host "Press Enter to close"

    exit 0
}