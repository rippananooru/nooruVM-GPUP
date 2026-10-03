#requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptRoot "config\gpu-p-repair.xml"

$VMName = $null
$VHDXPath = $null

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------

if (Test-Path -LiteralPath $ConfigFile) {

    Write-Host "Configuration found:"
    Write-Host "  $ConfigFile"
    Write-Host ""

    try {
        [xml]$Config = Get-Content -LiteralPath $ConfigFile -Raw

        $VMName = $Config.GPUPRepair.VMName
        $VHDXPath = $Config.GPUPRepair.VHDXPath
    }
    catch {
        Write-Warning "Configuration file could not be read."
    }
}

# ------------------------------------------------------------
# Ask user if configuration is missing/incomplete
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($VMName)) {
    $VMName = Read-Host "Enter Hyper-V VM name"
}

if ([string]::IsNullOrWhiteSpace($VHDXPath)) {
    $VHDXPath = Read-Host "Enter VHDX path"
}

Write-Host ""
Write-Host "Using configuration:" -ForegroundColor Cyan
Write-Host "  VM    : $VMName"
Write-Host "  VHDX  : $VHDXPath"
Write-Host ""

$DriverName = "u0203304.inf_amd64_a6e5a337568ce3f0"
$DriverSource = "C:\Windows\System32\DriverStore\FileRepository\$DriverName"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " nooruVM GPU-P DRIVER REPAIR" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 1. Verify VM
# ------------------------------------------------------------

Write-Host "[1/8] Checking VM..."

$VM = Get-VM -Name $VMName

if (-not $VM) {
    throw "VM '$VMName' was not found."
}

Write-Host "      VM: $VMName"
Write-Host "      State: $($VM.State)"

# ------------------------------------------------------------
# 2. Verify VHDX
# ------------------------------------------------------------

Write-Host ""
Write-Host "[2/8] Checking VHDX..."

if (-not (Test-Path $VHDXPath)) {
    throw "VHDX not found: $VHDXPath"
}

Write-Host "      $VHDXPath"

# ------------------------------------------------------------
# 3. Verify AMD driver
# ------------------------------------------------------------

Write-Host ""
Write-Host "[3/8] Checking AMD driver..."

if (-not (Test-Path $DriverSource)) {
    throw "AMD driver package not found: $DriverSource"
}

Write-Host "      $DriverSource"

# ------------------------------------------------------------
# 4. Stop VM
# ------------------------------------------------------------

Write-Host ""
Write-Host "[4/8] Stopping VM..."

if ((Get-VM -Name $VMName).State -ne "Off") {
    Stop-VM -Name $VMName -Force
}

while ((Get-VM -Name $VMName).State -ne "Off") {
    Start-Sleep -Milliseconds 500
}

Write-Host "      VM stopped."

# ------------------------------------------------------------
# 5. Mount VHDX
# ------------------------------------------------------------

Write-Host ""
Write-Host "[5/8] Mounting VHDX..."

$MountedVHD = Mount-VHD `
    -Path $VHDXPath `
    -Passthru `
    -ErrorAction Stop

Start-Sleep -Seconds 2

$DiskNumber = $MountedVHD.DiskNumber

Write-Host "      Disk number: $DiskNumber"

# ------------------------------------------------------------
# 6. Locate Windows partition
# ------------------------------------------------------------

Write-Host ""
Write-Host "[6/8] Locating Windows partition..."

$Partitions = Get-Partition -DiskNumber $DiskNumber |
    Where-Object {
        $_.Size -gt 20GB
    } |
    Sort-Object Size -Descending

$Partition = $null

foreach ($P in $Partitions) {

    if ($P.DriveLetter) {

        $Candidate = "$($P.DriveLetter):\Windows"

        if (Test-Path $Candidate) {
            $Partition = $P
            break
        }
    }
}

if (-not $Partition) {

    Write-Host "      Windows partition has no drive letter. Assigning Z:"

    $Partition = $Partitions | Select-Object -First 1

    if (-not $Partition) {
        Dismount-VHD -Path $VHDXPath
        throw "Could not find Windows partition."
    }

    Set-Partition `
        -DiskNumber $DiskNumber `
        -PartitionNumber $Partition.PartitionNumber `
        -NewDriveLetter "Z"

    $DriveLetter = "Z"
}
else {
    $DriveLetter = $Partition.DriveLetter
}

$GuestWindows = "${DriveLetter}:\Windows"
$GuestDriverStore = "$GuestWindows\System32\HostDriverStore\FileRepository"

Write-Host "      Windows: $GuestWindows"
Write-Host "      HostDriverStore: $GuestDriverStore"

# ------------------------------------------------------------
# 7. Copy AMD driver
# ------------------------------------------------------------

Write-Host ""
Write-Host "[7/8] Copying AMD GPU-P driver..."
Write-Host ""
Write-Host "      SOURCE:"
Write-Host "      $DriverSource"
Write-Host ""
Write-Host "      DESTINATION:"
Write-Host "      $GuestDriverStore\$DriverName"
Write-Host ""

if (-not (Test-Path $GuestDriverStore)) {
    New-Item `
        -ItemType Directory `
        -Path $GuestDriverStore `
        -Force | Out-Null
}

$DriverDestination = Join-Path $GuestDriverStore $DriverName

robocopy `
    $DriverSource `
    $DriverDestination `
    /E `
    /COPY:DAT `
    /DCOPY:DAT `
    /ZB `
    /XF `
        "atikmdag_dce_3.log" `
        "HDCPSrmData.txt" `
    /R:1 `
    /W:1 `
    /NFL `
    /NDL `
    /NJH `
    /NJS

$RobocopyCode = $LASTEXITCODE

if ($RobocopyCode -ge 8) {
    Dismount-VHD -Path $VHDXPath -ErrorAction SilentlyContinue
    throw "Robocopy failed with exit code $RobocopyCode."
}

# Verify critical AMD driver files recursively

$RequiredFiles = @(
    "amdkmdag.sys",
    "amdxc64.dll",
    "amdxx64.dll",
    "amdadlx64.dll"
)

foreach ($File in $RequiredFiles) {

    $Check = Get-ChildItem `
        -Path $DriverDestination `
        -Filter $File `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $Check) {
        Dismount-VHD -Path $VHDXPath -ErrorAction SilentlyContinue
        throw "Missing required AMD driver file: $File"
    }

    Write-Host "      [OK] $File -> $($Check.FullName)"
}

Write-Host ""
Write-Host "      AMD driver copied successfully."

# ------------------------------------------------------------
# 8. Dismount and start VM
# ------------------------------------------------------------

Write-Host ""
Write-Host "[8/8] Dismounting VHDX..."

Dismount-VHD -Path $VHDXPath -ErrorAction Stop

Write-Host "      VHDX dismounted."

Write-Host ""
Write-Host "      Starting $VMName..."

Start-VM -Name $VMName -ErrorAction Stop

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " GPU-P DRIVER REPAIR COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "VM started: $VMName"
Write-Host ""
Write-Host "Wait for Windows to boot, then check:"
Write-Host "Device Manager -> Display adapters"
Write-Host ""
Write-Host "Expected:"
Write-Host "AMD Radeon RX 9070 XT"
Write-Host "Code 43 should be gone."
Write-Host ""

Read-Host "Press ENTER to close"
