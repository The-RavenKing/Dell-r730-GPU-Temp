# PowerShell script to configure Discrete Device Assignment (DDA) for Nvidia GPUs on Hyper-V
# Run this on the Windows HOST as Administrator

param(
    [string]$VmName
)

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "   Dell R730 - Hyper-V GPU Passthrough (DDA)  " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# Check for Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run this script as Administrator!"
    exit 1
}

# 1. Select VM
if ([string]::IsNullOrEmpty($VmName)) {
    Write-Host "`nAvailable VMs:" -ForegroundColor Yellow
    Get-VM | Select-Object Name, State
    $VmName = Read-Host "`nEnter the name of your Ubuntu VM"
}

$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM '$VmName' not found!"
    exit 1
}
Write-Host "Selected VM: $($vm.Name)" -ForegroundColor Green

# 2. Find Nvidia GPUs
Write-Host "`nScanning for Nvidia GPUs..." -ForegroundColor Yellow

# Try to find by driver service first (preferred)
$gpus = Get-PnpDevice | Where-Object { $_.Class -eq "Display" -and $_.Service -like "*nvlddmkm*" }

# Fallback: Find by Vendor ID (10DE = Nvidia) if driver is missing or generic
if ($gpus.Count -eq 0) {
    Write-Host "Driver not found, searching by Vendor ID (10DE)..." -ForegroundColor Gray
    # Look for Display class first
    $gpus = Get-PnpDevice | Where-Object { $_.Class -eq "Display" -and $_.InstanceId -like "*VEN_10DE*" }
    
    # If still nothing, look for 3D Video Controller (sometimes how it appears without drivers)
    if ($gpus.Count -eq 0) {
        $gpus = Get-PnpDevice | Where-Object { $_.InstanceId -like "*PCI\VEN_10DE*" }
    }
}

if ($gpus.Count -eq 0) {
    Write-Error "Crucial Error: No Nvidia devices found (Vendor ID 10DE)."
    exit 1
}

# List found GPUs
$i = 0
foreach ($gpu in $gpus) {
    Write-Host "[$i] $($gpu.FriendlyName) ($($gpu.InstanceId))"
    $i++
}

# Select GPU
if ($gpus.Count -gt 1) {
    $selection = Read-Host "Select GPU to pass through (0-$($gpus.Count - 1))"
    $selectedGpu = $gpus[[int]$selection]
}
else {
    $selectedGpu = $gpus[0]
}

Write-Host "Target GPU: $($selectedGpu.FriendlyName)" -ForegroundColor Green

# 3. Validation
$locPath = (Get-PnpDeviceProperty -KeyName DEVPKEY_Device_LocationPaths -InstanceId $selectedGpu.InstanceId).Data[0]
if (-not $locPath) {
    Write-Error "Could not determine Location Path for device. DDA requires a Location Path."
    exit 1
}
Write-Host "Location Path: $locPath" -ForegroundColor Gray

# Confirm action
Write-Warning "This will remove the GPU from Windows and assign it to '$VmName'."
Write-Warning "Your screen might flicker or go black if this is your primary GPU."
$confirm = Read-Host "Type 'YES' to proceed"
if ($confirm -ne "YES") {
    Write-Host "Aborted."
    exit 0
}

# 4. Perform DDA
try {
    # STOP VM if running (DDA requires VM to be off to change settings)
    if ($vm.State -eq 'Running') {
        Write-Warning "VM '$VmName' is running. It must be stopped to configure DDA."
        Write-Host "Stopping VM..." -ForegroundColor Yellow
        Stop-VM -Name $VmName -Force
    }

    Write-Host "`nDisabling device in Windows..." -ForegroundColor Yellow
    Disable-PnpDevice -InstanceId $selectedGpu.InstanceId -Confirm:$false

    Write-Host "Dismounting device from Host..." -ForegroundColor Yellow
    Dismount-VMHostAssignableDevice -LocationPath $locPath -Force -ErrorAction SilentlyContinue

    Write-Host "Configuring VM settings for DDA..." -ForegroundColor Yellow
    # Set AutomaticStopAction FIRST (Critical constraint)
    Set-VM -VMName $VmName -AutomaticStopAction TurnOff
    
    # Configure Memory
    Set-VM -VMName $VmName -GuestControlledCacheTypes $true
    Set-VM -VMName $VmName -LowMemoryMappedIoSpace 3Gb
    Set-VM -VMName $VmName -HighMemoryMappedIoSpace 33Gb

    Write-Host "Assigning device to VM..." -ForegroundColor Yellow
    Add-VMAssignableDevice -VMName $VmName -LocationPath $locPath

    Write-Host "`nSUCCESS! GPU assigned to $VmName." -ForegroundColor Green
    Write-Host "Please start/reboot the Ubuntu VM and install drivers:"
    Write-Host "  sudo ubuntu-drivers autoinstall"
    Write-Host "  sudo reboot"
}
catch {
    Write-Error "An error occurred during DDA configuration: $($_.Exception.Message)"
    Write-Host "Attempting to re-enable device in Windows..."
    Enable-PnpDevice -InstanceId $selectedGpu.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
}
