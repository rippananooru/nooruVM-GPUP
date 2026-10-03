# nooruLAPTOP - G923 USB/IP Host
# Automatically requests Administrator privileges

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Self-elevate
# ------------------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
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

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
$Port = 3240
$RuleName = "USBIP - Allow TCP 3240"

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "       nooruLAPTOP - G923 HOST" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# Make sure usbipd service is running
# ------------------------------------------------------------
$service = Get-Service -Name "usbipd" -ErrorAction SilentlyContinue

if (-not $service) {
    Write-Host "ERROR: usbipd service not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

if ($service.Status -ne "Running") {
    Write-Host "Starting usbipd service..."
    Start-Service usbipd
    Start-Sleep -Seconds 1
}

Write-Host "usbipd service: Running" -ForegroundColor Green

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------
$rule = Get-NetFirewallRule `
    -DisplayName $RuleName `
    -ErrorAction SilentlyContinue

if (-not $rule) {

    Write-Host "Creating firewall rule..."

    try {
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
    catch {
        Write-Host "ERROR: Could not create firewall rule." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }

}
else {
    Write-Host "Firewall rule: Already exists" -ForegroundColor Green
}

# ------------------------------------------------------------
# Find G923 dynamically
# Logitech G923:
# VID = 046D
# PID = C266 or C267 depending on enumeration
# ------------------------------------------------------------
Write-Host ""
Write-Host "Searching for Logitech G923..." -ForegroundColor Cyan

$list = usbipd list

$g923Line = $list |
    Where-Object {
        $_ -match '^\s*\S+\s+046d:c26[67]\s+'
    } |
    Select-Object -First 1

if (-not $g923Line) {

    Write-Host ""
    Write-Host "ERROR: Logitech G923 not found." -ForegroundColor Red
    Write-Host ""
    usbipd list

    Read-Host "Press Enter to exit"
    exit 1
}

# Extract BUSID
$parts = ($g923Line -split '\s+') |
    Where-Object { $_ -ne "" }

$BusId = $parts[0]
$VidPid = $parts[1]

Write-Host "G923 detected:" -ForegroundColor Green
Write-Host "  Bus ID : $BusId"
Write-Host "  VID:PID: $VidPid"

# ------------------------------------------------------------
# Check state and share if necessary
# ------------------------------------------------------------
$currentLine = (usbipd list |
    Where-Object {
        $_ -match "^\s*$BusId\s+"
    } |
    Select-Object -First 1)

if ($currentLine -match '\bNot shared\b') {

    Write-Host ""
    Write-Host "Sharing G923 on bus $BusId..."

    usbipd bind --busid $BusId

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "ERROR: Failed to share G923." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }

    Write-Host "G923: Shared" -ForegroundColor Green

}
elseif ($currentLine -match '\bShared\b') {

    Write-Host ""
    Write-Host "G923: Already shared" -ForegroundColor Green

}
else {

    Write-Host ""
    Write-Host "ERROR: Could not determine G923 sharing state." -ForegroundColor Red
    Write-Host $currentLine
    Read-Host "Press Enter to exit"
    exit 1
}

# ------------------------------------------------------------
# Verify
# ------------------------------------------------------------
Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "       G923 USB/IP HOST READY" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""

Write-Host "Tailscale : 100.124.104.125"
Write-Host "Port      : 3240"
Write-Host "Bus ID    : $BusId"
Write-Host "VID:PID   : $VidPid"

Write-Host ""
usbipd list

Write-Host ""
Read-Host "Press Enter to close"