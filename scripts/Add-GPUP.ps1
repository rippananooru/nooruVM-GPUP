#requires -RunAsAdministrator

<#
.SYNOPSIS
    Add or update a GPU-P partition on a Hyper-V VM.

.DESCRIPTION
    Reads the existing config\gpup.xml created by
    Add-GPUP-Addconfig.ps1.

    gpup.xml is the single source of truth.

    This script does NOT create or modify gpup.xml.
#>

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

function Get-ConfigUInt64 {
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

    [UInt64]$Result = 0

    if (-not [UInt64]::TryParse(
        $Text,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$Result
    )) {
        throw "Configuration value <$Name> is not a valid UInt64: $Text"
    }

    return $Result
}

function Get-ConfigInt32 {
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

    [Int32]$Result = 0

    if (-not [Int32]::TryParse(
        $Text,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$Result
    )) {
        throw "Configuration value <$Name> is not a valid Int32: $Text"
    }

    return $Result
}

function Show-AdapterValues {
    param(
        [Parameter(Mandatory)]
        $Adapter
    )

    Write-Host ""
    Write-Host "      GPU-P adapter values:" -ForegroundColor Cyan

    Write-Host ("      MinVRAM        : {0}" -f $Adapter.MinPartitionVRAM)
    Write-Host ("      MaxVRAM        : {0}" -f $Adapter.MaxPartitionVRAM)
    Write-Host ("      OptimalVRAM    : {0}" -f $Adapter.OptimalPartitionVRAM)

    Write-Host ("      MinEncode      : {0}" -f $Adapter.MinPartitionEncode)
    Write-Host ("      MaxEncode      : {0}" -f $Adapter.MaxPartitionEncode)
    Write-Host ("      OptimalEncode  : {0}" -f $Adapter.OptimalPartitionEncode)

    Write-Host ("      MinDecode      : {0}" -f $Adapter.MinPartitionDecode)
    Write-Host ("      MaxDecode      : {0}" -f $Adapter.MaxPartitionDecode)
    Write-Host ("      OptimalDecode  : {0}" -f $Adapter.OptimalPartitionDecode)

    Write-Host ("      MinCompute     : {0}" -f $Adapter.MinPartitionCompute)
    Write-Host ("      MaxCompute     : {0}" -f $Adapter.MaxPartitionCompute)
    Write-Host ("      OptimalCompute : {0}" -f $Adapter.OptimalPartitionCompute)
}

function Test-AdapterValue {
    param(
        [Parameter(Mandatory)]
        $Actual,

        [Parameter(Mandatory)]
        [UInt64]$Expected
    )

    try {
        return ([UInt64]$Actual -eq $Expected)
    }
    catch {
        return $false
    }
}


# ============================================================
# HEADER
# ============================================================

Clear-Host

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " ADD GPU-P PARTITION" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan


# ============================================================
# 1/7 - HYPER-V / GPU-P
# ============================================================

Write-Step "1/7" "Checking Hyper-V"

try {
    Import-Module Hyper-V -ErrorAction Stop
    Write-OK "Hyper-V PowerShell module detected."
}
catch {
    throw "Hyper-V PowerShell module is not available."
}

$RequiredCmdlets = @(
    "Get-VMHostPartitionableGpu",
    "Get-VMGpuPartitionAdapter",
    "Add-VMGpuPartitionAdapter",
    "Set-VMGpuPartitionAdapter"
)

foreach ($Cmdlet in $RequiredCmdlets) {
    if (-not (Get-Command $Cmdlet -ErrorAction SilentlyContinue)) {
        throw "Required GPU-P cmdlet not found: $Cmdlet"
    }
}

Write-OK "GPU-P PowerShell cmdlets detected."


# ============================================================
# 2/7 - LOAD CONFIGURATION
# ============================================================

Write-Step "2/7" "Loading GPU-P configuration"

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
    throw "Could not read GPU-P configuration file:`n$($_.Exception.Message)"
}

if ($null -eq $Config.GPUP) {
    throw "Invalid configuration file. Root element <GPUP> was not found."
}


# ------------------------------------------------------------
# VM
# ------------------------------------------------------------

$VMName = Read-ConfigString `
    -Value $Config.GPUP.VMName `
    -Name "VMName"

$VHDXPath = Read-ConfigString `
    -Value $Config.GPUP.VHDXPath `
    -Name "VHDXPath"

Write-Host "      VM:   $VMName"
Write-Host "      VHDX: $VHDXPath"


# ------------------------------------------------------------
# GPU-P RESOURCE VALUES
# ------------------------------------------------------------

$PartitionCount = Get-ConfigInt32 `
    -Value $Config.GPUP.PartitionCount `
    -Name "PartitionCount"

$MinVRAM = Get-ConfigUInt64 `
    -Value $Config.GPUP.VRAM.Min `
    -Name "VRAM.Min"

$MaxVRAM = Get-ConfigUInt64 `
    -Value $Config.GPUP.VRAM.Max `
    -Name "VRAM.Max"

$OptimalVRAM = Get-ConfigUInt64 `
    -Value $Config.GPUP.VRAM.Optimal `
    -Name "VRAM.Optimal"

$MinEncode = Get-ConfigUInt64 `
    -Value $Config.GPUP.Encode.Min `
    -Name "Encode.Min"

$MaxEncode = Get-ConfigUInt64 `
    -Value $Config.GPUP.Encode.Max `
    -Name "Encode.Max"

$OptimalEncode = Get-ConfigUInt64 `
    -Value $Config.GPUP.Encode.Optimal `
    -Name "Encode.Optimal"

$MinDecode = Get-ConfigUInt64 `
    -Value $Config.GPUP.Decode.Min `
    -Name "Decode.Min"

$MaxDecode = Get-ConfigUInt64 `
    -Value $Config.GPUP.Decode.Max `
    -Name "Decode.Max"

$OptimalDecode = Get-ConfigUInt64 `
    -Value $Config.GPUP.Decode.Optimal `
    -Name "Decode.Optimal"

$MinCompute = Get-ConfigUInt64 `
    -Value $Config.GPUP.Compute.Min `
    -Name "Compute.Min"

$MaxCompute = Get-ConfigUInt64 `
    -Value $Config.GPUP.Compute.Max `
    -Name "Compute.Max"

$OptimalCompute = Get-ConfigUInt64 `
    -Value $Config.GPUP.Compute.Optimal `
    -Name "Compute.Optimal"

Write-OK "Configuration loaded."


# ============================================================
# 3/7 - VM VALIDATION
# ============================================================

Write-Step "3/7" "Checking VM"

$VM = Get-VM `
    -Name $VMName `
    -ErrorAction SilentlyContinue

if ($null -eq $VM) {
    throw "Hyper-V VM not found: $VMName"
}

Write-OK "VM found: $($VM.Name)"
Write-Host "      State: $($VM.State)"

if (Test-Path -LiteralPath $VHDXPath) {
    Write-OK "Configured VHDX exists."
}
else {
    Write-Warn "Configured VHDX was not found:"
    Write-Host "      $VHDXPath"
}


# ============================================================
# 4/7 - PARTITIONABLE GPU
# ============================================================

Write-Step "4/7" "Checking partitionable GPU"

$PartitionableGpus = @(
    Get-VMHostPartitionableGpu `
        -ErrorAction SilentlyContinue
)

if ($PartitionableGpus.Count -eq 0) {
    throw "No partitionable GPU detected."
}

Write-OK "Partitionable GPU detected."

$Gpu = $PartitionableGpus | Select-Object -First 1

$GpuInstancePath = $Gpu.Name

if ([string]::IsNullOrWhiteSpace($GpuInstancePath)) {
    throw "Could not determine the GPU instance path."
}

Write-Host "      GPU:"
Write-Host "      $GpuInstancePath"


# ------------------------------------------------------------
# Partition count
# ------------------------------------------------------------

if ($PartitionCount -le 0) {
    throw "PartitionCount must be greater than zero."
}

if ($Gpu.ValidPartitionCounts) {

    $ValidCounts = @(
        $Gpu.ValidPartitionCounts
    )

    if ($ValidCounts -notcontains $PartitionCount) {
        throw @"
Configured PartitionCount $PartitionCount is not supported by this GPU.

Valid values:
$($ValidCounts -join ', ')
"@
    }
}

Write-OK "Partition count $PartitionCount is supported."


# ============================================================
# 5/7 - STOP VM
# ============================================================

Write-Step "5/7" "Preparing VM"

if ($VM.State -ne "Off") {

    Write-Warn "VM is currently $($VM.State)."
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

    Write-OK "VM stopped."
}
else {
    Write-OK "VM is already Off."
}


# ============================================================
# 6/7 - ADD / UPDATE GPU-P ADAPTER
# ============================================================

Write-Step "6/7" "Configuring GPU-P adapter"

$Adapter = Get-VMGpuPartitionAdapter `
    -VMName $VMName `
    -ErrorAction SilentlyContinue

if ($null -eq $Adapter) {

    Write-Host "      No GPU-P adapter found."
    Write-Host "      Adding GPU-P adapter..."

    Add-VMGpuPartitionAdapter `
        -VMName $VMName `
        -InstancePath $GpuInstancePath `
        -MinPartitionVRAM $MinVRAM `
        -MaxPartitionVRAM $MaxVRAM `
        -OptimalPartitionVRAM $OptimalVRAM `
        -MinPartitionEncode $MinEncode `
        -MaxPartitionEncode $MaxEncode `
        -OptimalPartitionEncode $OptimalEncode `
        -MinPartitionDecode $MinDecode `
        -MaxPartitionDecode $MaxDecode `
        -OptimalPartitionDecode $OptimalDecode `
        -MinPartitionCompute $MinCompute `
        -MaxPartitionCompute $MaxCompute `
        -OptimalPartitionCompute $OptimalCompute `
        -ErrorAction Stop

    Write-OK "GPU-P adapter added."
}
else {

    Write-Host "      GPU-P adapter already exists."
    Write-Host "      Updating GPU-P adapter..."

    Set-VMGpuPartitionAdapter `
        -VMName $VMName `
        -MinPartitionVRAM $MinVRAM `
        -MaxPartitionVRAM $MaxVRAM `
        -OptimalPartitionVRAM $OptimalVRAM `
        -MinPartitionEncode $MinEncode `
        -MaxPartitionEncode $MaxEncode `
        -OptimalPartitionEncode $OptimalEncode `
        -MinPartitionDecode $MinDecode `
        -MaxPartitionDecode $MaxDecode `
        -OptimalPartitionDecode $OptimalDecode `
        -MinPartitionCompute $MinCompute `
        -MaxPartitionCompute $MaxCompute `
        -OptimalPartitionCompute $OptimalCompute `
        -ErrorAction Stop

    Write-OK "GPU-P adapter updated."
}


# ============================================================
# 7/7 - VERIFY
# ============================================================

Write-Step "7/7" "Verifying GPU-P configuration"

$Adapter = Get-VMGpuPartitionAdapter `
    -VMName $VMName `
    -ErrorAction SilentlyContinue

if ($null -eq $Adapter) {
    throw "GPU-P adapter could not be found after configuration."
}

Show-AdapterValues -Adapter $Adapter

$Checks = @(
    @{
        Name     = "VRAM Max"
        Actual   = $Adapter.MaxPartitionVRAM
        Expected = $MaxVRAM
    }
    @{
        Name     = "VRAM Optimal"
        Actual   = $Adapter.OptimalPartitionVRAM
        Expected = $OptimalVRAM
    }
    @{
        Name     = "Encode Max"
        Actual   = $Adapter.MaxPartitionEncode
        Expected = $MaxEncode
    }
    @{
        Name     = "Encode Optimal"
        Actual   = $Adapter.OptimalPartitionEncode
        Expected = $OptimalEncode
    }
    @{
        Name     = "Decode Max"
        Actual   = $Adapter.MaxPartitionDecode
        Expected = $MaxDecode
    }
    @{
        Name     = "Decode Optimal"
        Actual   = $Adapter.OptimalPartitionDecode
        Expected = $OptimalDecode
    }
    @{
        Name     = "Compute Max"
        Actual   = $Adapter.MaxPartitionCompute
        Expected = $MaxCompute
    }
    @{
        Name     = "Compute Optimal"
        Actual   = $Adapter.OptimalPartitionCompute
        Expected = $OptimalCompute
    }
)

$FailedChecks = @()

foreach ($Check in $Checks) {

    if (-not (
        Test-AdapterValue `
            -Actual $Check.Actual `
            -Expected $Check.Expected
    )) {
        $FailedChecks += $Check.Name
    }
}

Write-Host ""

if ($FailedChecks.Count -eq 0) {

    Write-OK "All GPU-P values verified successfully."

}
else {

    Write-Host "      GPU-P verification failed:" -ForegroundColor Red

    foreach ($Name in $FailedChecks) {
        Write-Host "      - $Name" -ForegroundColor Red
    }

    throw "GPU-P adapter verification failed."
}


# ============================================================
# START VM
# ============================================================

Write-Host ""

$StartVM = Read-Host "Start VM now? [Y/N]"

if ($StartVM -match "^[Yy]$") {

    Write-Host ""
    Write-Host "      Starting VM..." -ForegroundColor Cyan

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

    Write-Host ""
    Write-Warn "VM remains Off."
}


# ============================================================
# COMPLETE
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " GPU-P CONFIGURATION COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "      VM:         $VMName"
Write-Host "      VHDX:       $VHDXPath"
Write-Host "      Partitions: $PartitionCount"
Write-Host ""