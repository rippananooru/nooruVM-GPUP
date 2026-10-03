#requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$ScriptRoot = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptRoot

$ConfigFile = Join-Path $RepoRoot "config\gpup.xml"


# ============================================================
# HELPERS
# ============================================================

function Write-Step {
    param(
        [string]$Number,
        [string]$Text
    )

    Write-Host ""
    Write-Host "[$Number] $Text..." -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Text)

    Write-Host "      $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)

    Write-Host "      $Text" -ForegroundColor Yellow
}

function Read-ConfigString {
    param(
        [Parameter(Mandatory)]
        $Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Value) {
        throw "Configuration value <$Name> is missing."
    }

    $Text = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw "Configuration value <$Name> is empty."
    }

    return $Text
}


# ============================================================
# HEADER
# ============================================================

Clear-Host

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " GPU-P CODE 43 DRIVER REPAIR" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan


# ============================================================
# 1/8 - LOAD CONFIGURATION
# ============================================================

Write-Step "1/8" "Loading GPU-P configuration"

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    throw @"
GPU-P configuration not found:

$ConfigFile

Run Menu [1] first.
"@
}

Write-OK "Configuration found:"
Write-Host "      $ConfigFile"

try {
    [xml]$Config = Get-Content `
        -LiteralPath $ConfigFile `
        -Raw `
        -ErrorAction Stop
}
catch {
    throw "Could not read GPU-P configuration:`n$($_.Exception.Message)"
}

if ($null -eq $Config.GPUP) {
    throw "Invalid configuration file. Root element <GPUP> was not found."
}

$VMName = Read-ConfigString `
    -Value $Config.GPUP.VMName `
    -Name "VMName"

$VHDXPath = Read-ConfigString `
    -Value $Config.GPUP.VHDXPath `
    -Name "VHDXPath"

$GPUVendor = Read-ConfigString `
    -Value $Config.GPUP.GPUVendor `
    -Name "GPUVendor"

$GPUVendor = $GPUVendor.ToUpperInvariant()

Write-Host "      VM:          $VMName"
Write-Host "      GPU Vendor:  $GPUVendor"
Write-Host "      VHDX:        $VHDXPath"


# ============================================================
# VENDOR SELECTION
# ============================================================

switch ($GPUVendor) {

    "AMD" {
        Write-OK "AMD GPU-P repair selected."
    }

    "NVIDIA" {
        Write-Warn "NVIDIA GPU-P repair is not implemented yet."
        Write-Host ""
        Write-Host "      NVIDIA support can be added later."
        exit 1
    }

    "INTEL" {
        Write-Warn "Intel GPU-P repair is not implemented yet."
        Write-Host ""
        Write-Host "      Intel support can be added later."
        exit 1
    }

    default {
        throw "Unsupported GPU vendor: $GPUVendor"
    }
}


# ============================================================
# 2/8 - CHECK VM
# ============================================================

Write-Step "2/8" "Checking VM"

$VM = Get-VM `
    -Name $VMName `
    -ErrorAction SilentlyContinue

if ($null -eq $VM) {
    throw "VM '$VMName' was not found."
}

Write-OK "VM found: $VMName"
Write-Host "      State: $($VM.State)"


# ============================================================
# 3/8 - CHECK VHDX AND DRIVER
# ============================================================

Write-Step "3/8" "Checking VHDX and AMD GPU-P driver"

if (-not (Test-Path -LiteralPath $VHDXPath)) {
    throw "VHDX not found: $VHDXPath"
}

Write-OK "VHDX found:"
Write-Host "      $VHDXPath"


# ============================================================
# AMD DRIVER DETECTION
# ============================================================

$DriverStore = "C:\Windows\System32\DriverStore\FileRepository"

if (-not (Test-Path -LiteralPath $DriverStore)) {
    throw "Host DriverStore not found: $DriverStore"
}

Write-Host ""
Write-Host "      Searching host DriverStore for AMD display driver..."

$AMDDrivers = @(
    Get-ChildItem `
        -Path $DriverStore `
        -Directory `
        -ErrorAction Stop |
    Where-Object {
        $_.Name -like "u*.inf_amd64_*"
    } |
    Where-Object {
        Get-ChildItem `
            -Path $_.FullName `
            -Filter "amdkmdag.sys" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Select-Object -First 1
    } |
    Sort-Object LastWriteTime -Descending
)

if ($AMDDrivers.Count -eq 0) {
    throw "Could not find an AMD display driver package containing amdkmdag.sys."
}

$DriverPackage = $AMDDrivers | Select-Object -First 1

$DriverName = $DriverPackage.Name
$DriverSource = $DriverPackage.FullName

Write-OK "AMD driver package found:"
Write-Host "      $DriverName"
Write-Host "      $DriverSource"


# ============================================================
# 4/8 - STOP VM
# ============================================================

Write-Step "4/8" "Stopping VM"

$VM = Get-VM `
    -Name $VMName `
    -ErrorAction Stop

if ($VM.State -ne "Off") {

    Write-Host "      Current state: $($VM.State)"
    Write-Host "      Stopping VM..."

    Stop-VM `
        -Name $VMName `
        -Force `
        -TurnOff `
        -ErrorAction Stop

    do {
        Start-Sleep -Milliseconds 500

        $VM = Get-VM `
            -Name $VMName `
            -ErrorAction Stop

    } while ($VM.State -ne "Off")
}

Write-OK "VM stopped."


# ============================================================
# 5/8 - MOUNT VHDX
# ============================================================

Write-Step "5/8" "Mounting VHDX"

$MountedVHD = $null
$DiskNumber = $null
$DriveLetter = $null
$VHDMountedByScript = $false

try {

    $MountedVHD = Mount-VHD `
        -Path $VHDXPath `
        -Passthru `
        -ErrorAction Stop

    $VHDMountedByScript = $true
    $DiskNumber = $MountedVHD.DiskNumber

    Start-Sleep -Seconds 2

    Write-OK "VHDX mounted."
    Write-Host "      Disk number: $DiskNumber"

    Write-Host ""
    Write-Host "      Locating Windows partition..."

    $Partitions = @(
        Get-Partition `
            -DiskNumber $DiskNumber `
            -ErrorAction Stop |
        Where-Object {
            $_.Size -gt 20GB
        } |
        Sort-Object Size -Descending
    )

    $Partition = $null

    foreach ($P in $Partitions) {

        if ($P.DriveLetter) {

            $Candidate = "$($P.DriveLetter):\Windows"

            if (Test-Path -LiteralPath $Candidate) {
                $Partition = $P
                break
            }
        }
    }

    if ($null -eq $Partition) {

        Write-Host "      Windows partition has no drive letter."
        Write-Host "      Assigning Z:"

        $Partition = $Partitions | Select-Object -First 1

        if ($null -eq $Partition) {
            throw "Could not find Windows partition."
        }

        Set-Partition `
            -DiskNumber $DiskNumber `
            -PartitionNumber $Partition.PartitionNumber `
            -NewDriveLetter "Z" `
            -ErrorAction Stop

        $DriveLetter = "Z"
    }
    else {
        $DriveLetter = $Partition.DriveLetter
    }

    $GuestWindows = "${DriveLetter}:\Windows"

    $GuestDriverStore = Join-Path `
        $GuestWindows `
        "System32\HostDriverStore\FileRepository"

    $DriverDestination = Join-Path `
        $GuestDriverStore `
        $DriverName

    Write-OK "Windows partition found:"
    Write-Host "      $GuestWindows"

    Write-Host ""
    Write-Host "      HostDriverStore:"
    Write-Host "      $GuestDriverStore"


    # ========================================================
    # 6/8 - COPY DRIVER
    # ========================================================

    Write-Step "6/8" "Copying AMD GPU-P driver"

    Write-Host ""
    Write-Host "      SOURCE:"
    Write-Host "      $DriverSource"

    Write-Host ""
    Write-Host "      DESTINATION:"
    Write-Host "      $DriverDestination"

    if (-not (Test-Path -LiteralPath $GuestDriverStore)) {

        New-Item `
            -ItemType Directory `
            -Path $GuestDriverStore `
            -Force | Out-Null
    }

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
        throw "Robocopy failed with exit code $RobocopyCode."
    }

    Write-OK "AMD driver package copied."


    # ========================================================
    # 7/8 - VERIFY DRIVER
    # ========================================================

    Write-Step "7/8" "Verifying AMD GPU-P driver"

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

        if ($null -eq $Check) {
            throw "Missing required AMD driver file: $File"
        }

        Write-OK "$File"
    }

    Write-OK "AMD GPU-P driver verified."


    # ========================================================
    # 8/8 - DISMOUNT
    # ========================================================

    Write-Step "8/8" "Dismounting VHDX"

    Dismount-VHD `
        -Path $VHDXPath `
        -ErrorAction Stop

    $VHDMountedByScript = $false

    Write-OK "VHDX dismounted."

}
catch {

    if ($VHDMountedByScript) {

        Write-Host ""
        Write-Warn "Attempting to dismount VHDX after failure..."

        Dismount-VHD `
            -Path $VHDXPath `
            -ErrorAction SilentlyContinue
    }

    throw
}


# ============================================================
# START VM
# ============================================================

Write-Host ""

$StartVM = Read-Host "Start VM now? [Y/N]"

if ($StartVM -match "^[Yy]$") {

    Write-Host ""
    Write-Host "      Starting $VMName..." -ForegroundColor Cyan

    Start-VM `
        -Name $VMName `
        -ErrorAction Stop

    Start-Sleep -Seconds 2

    $VM = Get-VM `
        -Name $VMName `
        -ErrorAction Stop

    if ($VM.State -eq "Running") {
        Write-OK "VM started successfully."
    }
    else {
        Write-Warn "VM start command completed. Current state: $($VM.State)"
    }

}
else {

    Write-Warn "VM remains Off."
}


# ============================================================
# COMPLETE
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " GPU-P DRIVER REPAIR COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "      VM:          $VMName"
Write-Host "      GPU Vendor:  $GPUVendor"
Write-Host "      VHDX:        $VHDXPath"
Write-Host "      AMD Driver:  $DriverName"
Write-Host ""
Write-Host "      After Windows boots, check:"
Write-Host "      Device Manager -> Display adapters"
Write-Host ""
Write-Host "      Expected:"
Write-Host "      AMD Radeon RX 9070 XT"
Write-Host ""