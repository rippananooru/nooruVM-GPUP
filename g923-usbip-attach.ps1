# nooruVM - G923 USB/IP Auto Attach

$UsbIp = "C:\Program Files\USBip\usbip.exe"
$Server = "100.124.104.125"
$BusId = "2-2"
$Port = 3240

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "       nooruVM - G923 USB/IP" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $UsbIp)) {
    Write-Host "ERROR: USBIP client not found:" -ForegroundColor Red
    Write-Host $UsbIp
    Read-Host "Press Enter to exit"
    exit 1
}

# Check whether already attached
$ports = & $UsbIp port 2>$null

if ($ports -match [regex]::Escape($BusId)) {
    Write-Host "G923 is already attached." -ForegroundColor Green
    Write-Host ""
    & $UsbIp port
    Read-Host "Press Enter to close"
    exit 0
}

# Wait for USB/IP server
for ($i = 1; $i -le 60; $i++) {

    Write-Host "[Attempt $i/60] Checking $Server`:$Port..."

    if (-not (Test-NetConnection $Server -Port $Port -InformationLevel Quiet)) {
        Write-Host "  USB/IP server not reachable."
        Start-Sleep -Seconds 2
        continue
    }

    Write-Host "  USB/IP server reachable." -ForegroundColor Green

    # Check exported devices
    $devices = & $UsbIp list -r $Server 2>$null

    if ($devices -match [regex]::Escape($BusId)) {
        Write-Host "  G923 found on bus $BusId." -ForegroundColor Green

        # Double-check that it isn't already attached
        $ports = & $UsbIp port 2>$null

        if ($ports -match [regex]::Escape($BusId)) {
            Write-Host "  G923 is already attached." -ForegroundColor Green
            exit 0
        }

        Write-Host "  Attaching G923..."

        & $UsbIp attach -r $Server -b $BusId

        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "======================================" -ForegroundColor Green
            Write-Host "       G923 ATTACHED SUCCESSFULLY" -ForegroundColor Green
            Write-Host "======================================" -ForegroundColor Green
            Write-Host ""

            & $UsbIp port

            Write-Host ""
            Read-Host "Press Enter to close"
            exit 0
        }

        Write-Host "  Attach failed. Retrying..." -ForegroundColor Yellow
    }
    else {
        Write-Host "  G923 not exported yet."
    }

    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "ERROR: G923 could not be attached after 60 attempts." -ForegroundColor Red
Write-Host ""
Read-Host "Press Enter to exit"
exit 1