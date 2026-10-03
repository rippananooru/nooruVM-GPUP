# ============================================================
# USBIP-HOST.ps1
#
# USB/IP HOST
#
# Runs on the machine where the physical USB device is connected.
#
# Responsibilities:
#   - Ensure usbipd-win is installed
#   - Ensure usbipd service is running
#   - Ensure TCP 3240 is allowed
#   - Show local USB devices
#   - Allow user to share/unshare devices
#   - Maintain the shared active-host XML
#
# Shared XML:
#   config\usbip-host.xml
# ============================================================

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$Port = 3240
$RuleName = "USBIP - Allow TCP 3240"

$ConfigDirectory = Join-Path $PSScriptRoot "config"
$ConfigFile = Join-Path $ConfigDirectory "usbip-host.xml"

$WingetPackage = "dorssel.usbipd-win"

# ============================================================
# SELF ELEVATE
# ============================================================

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {

    Write-Host ""
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`""
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

    # Refresh PATH in this PowerShell process.
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

            $busId = $Matches[1]
            $vidPid = $Matches[2].ToLower()
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
            $_.State -match '^Shared$'
        }
    )
}

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
    # No shared devices = this host is no longer active.
    # --------------------------------------------------------

    if (-not $Devices -or $Devices.Count -eq 0) {

        if (Test-Path $ConfigFile) {

            try {

                [xml]$existing = Get-Content `
                    -LiteralPath $ConfigFile `
                    -Raw

                $existingName = [string]$existing.USBIP.Host.Name

                if ($existingName -eq $env:COMPUTERNAME) {

                    Remove-Item `
                        -LiteralPath $ConfigFile `
                        -Force `
                        -ErrorAction SilentlyContinue

                    Write-Host ""
                    Write-Host "No devices are currently shared." -ForegroundColor Yellow
                    Write-Host "Active USB/IP host removed from XML." -ForegroundColor Yellow
                }
            }
            catch {
            }
        }

        return $true
    }

    # --------------------------------------------------------
    # Get Tailscale address
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

    $settings.Indent = $true
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

    return $true
}

function Refresh-HostXml {

    $shared = Get-SharedDevices

    Publish-ActiveHost -Devices $shared | Out-Null

    return $shared
}

function Show-Devices {
    param(
        [array]$Devices
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "          LOCAL USB DEVICES" -ForegroundColor Cyan
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
        [array]$Devices
    )

    while ($true) {

        $selection = Read-Host "Select device number (Q to exit)"

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
# START
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "             USB/IP HOST" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
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
# REFRESH XML BEFORE SHOWING MENU
# ============================================================

Refresh-HostXml | Out-Null

# ============================================================
# MAIN LOOP
# ============================================================

while ($true) {

    $devices = Get-AllDevices

    if (-not $devices -or $devices.Count -eq 0) {

        Refresh-HostXml | Out-Null

        Write-Host ""
        Write-Host "No USB devices detected." -ForegroundColor Yellow
        Write-Host ""

        Read-Host "Press Enter to close"
        exit 0
    }

    Show-Devices -Devices $devices

    $selected = Select-Device -Devices $devices

    if (-not $selected) {

        Refresh-HostXml | Out-Null

        Write-Host ""
        Write-Host "Exiting." -ForegroundColor Yellow

        exit 0
    }

    Write-Host ""
    Write-Host "Selected:" -ForegroundColor Green
    Write-Host "  Bus ID : $($selected.BusId)"
    Write-Host "  VID:PID: $($selected.VidPid)"
    Write-Host "  Device : $($selected.Description)"
    Write-Host "  State  : $($selected.State)"
    Write-Host ""

    # --------------------------------------------------------
    # Already shared
    # --------------------------------------------------------

    if ($selected.State -eq "Shared") {

        Write-Host "This device is already shared." -ForegroundColor Yellow

        $again = Read-Host "Return to device list? [Y/N]"

        if ($again -match '^[Yy]$') {
            continue
        }

        exit 0
    }

    $confirm = Read-Host "Share this device? [Y/N]"

    if ($confirm -notmatch '^[Yy]$') {
        continue
    }

    # --------------------------------------------------------
    # Bind
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Sharing $($selected.BusId)..." -ForegroundColor Cyan

    & $UsbIpd bind --busid="$($selected.BusId)"

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host "ERROR: Failed to share device." -ForegroundColor Red
        Write-Host ""

        Refresh-HostXml | Out-Null

        $retry = Read-Host "Return to device list? [Y/N]"

        if ($retry -match '^[Yy]$') {
            continue
        }

        exit 1
    }

    Write-Host "Device shared successfully." -ForegroundColor Green

    Start-Sleep -Milliseconds 500

    # --------------------------------------------------------
    # Update active host XML
    # --------------------------------------------------------

    $shared = Refresh-HostXml

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "         USB/IP HOST ACTIVE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Host      : $env:COMPUTERNAME"
    Write-Host "Tailscale : $tailscaleIP"
    Write-Host "Port      : $Port"
    Write-Host ""
    Write-Host "Exported devices:" -ForegroundColor Cyan

    foreach ($device in $shared) {

        Write-Host "  $($device.BusId)  $($device.VidPid)  $($device.Description)"
    }

    Write-Host ""

    # --------------------------------------------------------
    # Another device?
    # --------------------------------------------------------

    $another = Read-Host "Share another USB device? [Y/N]"

    if ($another -match '^[Yy]$') {
        continue
    }

    Write-Host ""
    Write-Host "USB/IP host is ready." -ForegroundColor Green
    Write-Host ""

    Read-Host "Press Enter to close"

    exit 0
}