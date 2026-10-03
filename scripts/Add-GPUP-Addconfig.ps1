#requires -RunAsAdministrator

param(
    [string]$VMName,
    [string]$VHDXPath
)

$ErrorActionPreference = "Stop"

# ============================================================
# PATHS
# ============================================================

$ScriptRoot = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptRoot

$ConfigDirectory = Join-Path $RepoRoot "config"
$ConfigFile = Join-Path $ConfigDirectory "gpup.xml"

# ============================================================
# Helper functions
# ============================================================

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
}

function Get-UInt64Property {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    $Property = $Object.PSObject.Properties[$PropertyName]

    if ($null -eq $Property) {
        throw @"
The selected GPU does not expose the required property:

$PropertyName

Run:

    Get-VMHostPartitionableGpu

and verify the GPU properties exposed by your driver.
"@
    }

    try {
        return [UInt64]$Property.Value
    }
    catch {
        throw "Could not convert GPU property '$PropertyName' to UInt64."
    }
}

function Get-PartitionCounts {
    param(
        [Parameter(Mandatory)]
        [object]$GPU
    )

    if ($null -eq $GPU.ValidPartitionCounts) {
        throw "The selected GPU does not expose ValidPartitionCounts."
    }

    return @(
        $GPU.ValidPartitionCounts |
            ForEach-Object { [int]$_ }
    )
}

# ============================================================
# GPU VENDOR DETECTION
# ============================================================

$PartitionableGpu = Get-VMHostPartitionableGpu | Select-Object -First 1

if ($null -eq $PartitionableGpu) {
    throw "No partitionable GPU was detected on this host."
}

$GpuInstancePath = [string]$PartitionableGpu.Name

if ([string]::IsNullOrWhiteSpace($GpuInstancePath)) {
    throw "GPU instance path could not be determined."
}

if ($GpuInstancePath -match 'VEN_1002') {
    $GPUVendor = "AMD"
}
elseif ($GpuInstancePath -match 'VEN_10DE') {
    $GPUVendor = "NVIDIA"
}
elseif ($GpuInstancePath -match 'VEN_8086') {
    $GPUVendor = "Intel"
}
else {
    $GPUVendor = "Unknown"
}

Write-Host ""
Write-Host "GPU Vendor: $GPUVendor"
Write-Host "GPU Instance: $GpuInstancePath"

# ============================================================
# Header
# ============================================================

Write-Section "CREATE GPU-P CONFIGURATION"

Write-Host ""
Write-Host "This utility detects a partitionable GPU and creates:"
Write-Host ""
Write-Host "  $ConfigFile"
Write-Host ""

# ============================================================
# 1. Check Hyper-V / GPU-P
# ============================================================

Write-Host "[1/5] Checking GPU-P support..."

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw "Hyper-V PowerShell cmdlets are not available."
}

if (-not (Get-Command Get-VMHostPartitionableGpu -ErrorAction SilentlyContinue)) {
    throw "Get-VMHostPartitionableGpu is not available."
}

Write-Host "      Hyper-V detected."
Write-Host "      GPU-P cmdlets detected."

# ============================================================
# 2. Detect GPUs
# ============================================================

Write-Host ""
Write-Host "[2/5] Detecting partitionable GPUs..."

$GPUs = @(
    Get-VMHostPartitionableGpu
)

if ($GPUs.Count -eq 0) {

    throw @"
No partitionable GPU was detected.

Run:

    Get-VMHostPartitionableGpu

If nothing is returned, verify:

- GPU driver support
- IOMMU / AMD-Vi / VT-d
- SR-IOV / virtualization settings
- Hyper-V configuration
- GPU-P support from the installed driver
"@
}

Write-Host ""
Write-Host "      Partitionable GPUs found: $($GPUs.Count)"
Write-Host ""

# ============================================================
# Select GPU
# ============================================================

$SelectedGPU = $null

if ($GPUs.Count -eq 1) {

    $SelectedGPU = $GPUs[0]

    Write-Host "      One partitionable GPU detected."
    Write-Host "      Using it automatically."

}
else {

    Write-Host "      Multiple partitionable GPUs detected:"
    Write-Host ""

    for ($i = 0; $i -lt $GPUs.Count; $i++) {

        $GPU = $GPUs[$i]

        Write-Host "      [$($i + 1)]"
        Write-Host "          InstancePath:"
        Write-Host "          $($GPU.Name)"

        if ($null -ne $GPU.ValidPartitionCounts) {
            Write-Host ""
            Write-Host "          Valid partitions:"
            Write-Host "          $($GPU.ValidPartitionCounts -join ', ')"
        }

        Write-Host ""
    }

    do {

        $Selection = Read-Host "      Select GPU number"

        $SelectionNumber = 0

        $ValidSelection = [int]::TryParse(
            $Selection,
            [ref]$SelectionNumber
        )

    } until (
        $ValidSelection -and
        $SelectionNumber -ge 1 -and
        $SelectionNumber -le $GPUs.Count
    )

    $SelectedGPU = $GPUs[$SelectionNumber - 1]
}

$InstancePath = $SelectedGPU.Name

Write-Host ""
Write-Host "      Selected GPU:"
Write-Host "      $InstancePath" -ForegroundColor Green

# ============================================================
# 3. Read GPU capabilities
# ============================================================

Write-Host ""
Write-Host "[3/5] Reading GPU capabilities..."

$ValidPartitionCounts = Get-PartitionCounts -GPU $SelectedGPU

Write-Host ""
Write-Host "      Valid partition counts:"
Write-Host "      $($ValidPartitionCounts -join ', ')"

# ------------------------------------------------------------
# Partition count
# ------------------------------------------------------------

if ($ValidPartitionCounts.Count -eq 1) {

    $PartitionCount = $ValidPartitionCounts[0]

    Write-Host ""
    Write-Host "      Partition count:"
    Write-Host "      $PartitionCount"
    Write-Host "      Only supported value detected."

}
else {

    Write-Host ""
    Write-Host "      Multiple partition counts are supported."

    do {

        $PartitionInput = Read-Host `
            "      Select partition count [$($ValidPartitionCounts -join ', ')]"

        $PartitionCount = 0

        $ValidPartitionInput = [int]::TryParse(
            $PartitionInput,
            [ref]$PartitionCount
        )

    } until (
        $ValidPartitionInput -and
        ($ValidPartitionCounts -contains $PartitionCount)
    )
}

# ------------------------------------------------------------
# Resource capabilities
# ------------------------------------------------------------

Write-Host ""
Write-Host "      Reading resource capabilities..."

$TotalVRAM = Get-UInt64Property `
    -Object $SelectedGPU `
    -PropertyName "TotalVRAM"

$TotalEncode = Get-UInt64Property `
    -Object $SelectedGPU `
    -PropertyName "TotalEncode"

$TotalDecode = Get-UInt64Property `
    -Object $SelectedGPU `
    -PropertyName "TotalDecode"

$TotalCompute = Get-UInt64Property `
    -Object $SelectedGPU `
    -PropertyName "TotalCompute"

# ------------------------------------------------------------
# Configuration mapping
#
# Minimum  = 0
# Maximum  = total GPU capability
# Optimal  = total GPU capability
#
# This matches the working configuration model used by
# nooruVM.
# ------------------------------------------------------------

$MinVRAM = [UInt64]0
$MaxVRAM = $TotalVRAM
$OptimalVRAM = $TotalVRAM

$MinEncode = [UInt64]0
$MaxEncode = $TotalEncode
$OptimalEncode = $TotalEncode

$MinDecode = [UInt64]0
$MaxDecode = $TotalDecode
$OptimalDecode = $TotalDecode

$MinCompute = [UInt64]0
$MaxCompute = $TotalCompute
$OptimalCompute = $TotalCompute

# ============================================================
# 4. VM configuration
# ============================================================

Write-Host ""
Write-Host "[4/5] VM configuration..."

# ------------------------------------------------------------
# VM name
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($VMName)) {

    while ([string]::IsNullOrWhiteSpace($VMName)) {

        $VMName = Read-Host "      Enter Hyper-V VM name"

        if ([string]::IsNullOrWhiteSpace($VMName)) {
            Write-Host "      VM name cannot be empty." `
                -ForegroundColor Yellow
        }
    }
}
else {
    $VMName = $VMName.Trim()

    Write-Host "      VM name received from dashboard:"
    Write-Host "      $VMName"
}

# ------------------------------------------------------------
# VHDX path
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($VHDXPath)) {

    while ([string]::IsNullOrWhiteSpace($VHDXPath)) {

        $VHDXPath = Read-Host "      Enter VM VHDX path"

        if ([string]::IsNullOrWhiteSpace($VHDXPath)) {
            Write-Host "      VHDX path cannot be empty." `
                -ForegroundColor Yellow
        }
    }
}
else {
    $VHDXPath = $VHDXPath.Trim()

    Write-Host "      VHDX path received from dashboard:"
    Write-Host "      $VHDXPath"
}

# ------------------------------------------------------------
# Check whether VM exists
# ------------------------------------------------------------

$VM = Get-VM `
    -Name $VMName `
    -ErrorAction SilentlyContinue

if ($VM) {

    Write-Host ""
    Write-Host "      VM found:"
    Write-Host "      Name : $($VM.Name)"
    Write-Host "      State: $($VM.State)"

}
else {

    Write-Host ""
    Write-Host "      WARNING: VM '$VMName' does not currently exist." `
        -ForegroundColor Yellow

    Write-Host "      The configuration can still be created."
}

# ------------------------------------------------------------
# Check VHDX
# ------------------------------------------------------------

Write-Host ""

if (Test-Path -LiteralPath $VHDXPath) {

    $VHDXItem = Get-Item -LiteralPath $VHDXPath -ErrorAction SilentlyContinue

    if ($VHDXItem.PSIsContainer) {

        Write-Host "      ERROR: VHDX path points to a directory." `
            -ForegroundColor Red

        throw "Invalid VHDX path: $VHDXPath"
    }

    Write-Host "      VHDX found:"
    Write-Host "      $VHDXPath"

}
else {

    Write-Host "      WARNING: VHDX does not currently exist:" `
        -ForegroundColor Yellow

    Write-Host "      $VHDXPath"
    Write-Host "      The configuration can still be created."
}

# ============================================================
# 5. Generate XML
# ============================================================

Write-Host ""
Write-Host "[5/5] Creating GPU-P configuration..."

if (-not (Test-Path -LiteralPath $ConfigDirectory)) {

    New-Item `
        -ItemType Directory `
        -Path $ConfigDirectory `
        -Force | Out-Null
}

if (Test-Path -LiteralPath $ConfigFile) {

    Write-Host ""
    Write-Host "      Configuration already exists:"
    Write-Host "      $ConfigFile"

    $Overwrite = Read-Host "      Overwrite it? [Y/N]"

    if ($Overwrite -notmatch "^[Yy]$") {
        throw "Existing GPU-P configuration was not overwritten."
    }
}

$Xml = @"
<?xml version="1.0" encoding="utf-8"?>
<GPUP>
  <VMName>$VMName</VMName>
  <VHDXPath>$VHDXPath</VHDXPath>
  <GPUVendor>$GPUVendor</GPUVendor>

  <PartitionCount>$PartitionCount</PartitionCount>

  <VRAM>
    <Min>$MinVRAM</Min>
    <Max>$MaxVRAM</Max>
    <Optimal>$OptimalVRAM</Optimal>
  </VRAM>

  <Encode>
    <Min>$MinEncode</Min>
    <Max>$MaxEncode</Max>
    <Optimal>$OptimalEncode</Optimal>
  </Encode>

  <Decode>
    <Min>$MinDecode</Min>
    <Max>$MaxDecode</Max>
    <Optimal>$OptimalDecode</Optimal>
  </Decode>

  <Compute>
    <Min>$MinCompute</Min>
    <Max>$MaxCompute</Max>
    <Optimal>$OptimalCompute</Optimal>
  </Compute>
</GPUP>
"@

Set-Content `
    -LiteralPath $ConfigFile `
    -Value $Xml `
    -Encoding UTF8

# ============================================================
# Display result
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " GPU-P CONFIGURATION CREATED" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

Write-Host "Configuration:"
Write-Host "  $ConfigFile"

Write-Host ""
Write-Host "VM:"
Write-Host "  $VMName"

Write-Host ""
Write-Host "VHDX:"
Write-Host "  $VHDXPath"

Write-Host ""
Write-Host "GPU:"
Write-Host "  $InstancePath"

Write-Host ""
Write-Host "Partition count:"
Write-Host "  $PartitionCount"

Write-Host ""
Write-Host "VRAM:"
Write-Host "  Min     : $MinVRAM"
Write-Host "  Max     : $MaxVRAM"
Write-Host "  Optimal : $OptimalVRAM"

Write-Host ""
Write-Host "Encode:"
Write-Host "  Min     : $MinEncode"
Write-Host "  Max     : $MaxEncode"
Write-Host "  Optimal : $OptimalEncode"

Write-Host ""
Write-Host "Decode:"
Write-Host "  Min     : $MinDecode"
Write-Host "  Max     : $MaxDecode"
Write-Host "  Optimal : $OptimalDecode"

Write-Host ""
Write-Host "Compute:"
Write-Host "  Min     : $MinCompute"
Write-Host "  Max     : $MaxCompute"
Write-Host "  Optimal : $OptimalCompute"

Write-Host ""
Write-Host "The configuration is ready for Add-GPUP.ps1." -ForegroundColor Green
Write-Host ""

exit 0