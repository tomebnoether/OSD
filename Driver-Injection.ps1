<#
.SYNOPSIS
    Driver injection script for WinPE/OSDCloud deployment
.DESCRIPTION
    Installs drivers to offline Windows installation and WinRE environment
.NOTES
    Run this script in WinPE after OSDCloud deployment
#>

[CmdletBinding()]
param()

#region Helper Functions

function Write-StatusMessage {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Header')]
        [string]$Type = 'Info'
    )
    
    $colors = @{
        'Info'    = 'Cyan'
        'Success' = 'Green'
        'Warning' = 'Yellow'
        'Error'   = 'Red'
        'Header'  = 'Magenta'
    }
    
    $symbols = @{
        'Info'    = '[info]'
        'Success' = '[success]'
        'Warning' = '[warning]'
        'Error'   = '[error]'
        'Header'  = '======'
    }
    
    Write-Host "$($symbols[$Type]) $Message" -ForegroundColor $colors[$Type]
}

function Test-PathWithError {
    param(
        [string]$Path,
        [string]$Description
    )
    
    if (Test-Path $Path) {
        Write-StatusMessage "Found: $Description at $Path" -Type Success
        return $true
    } else {
        Write-StatusMessage "Not found: $Description at $Path" -Type Error
        return $false
    }
}

function Invoke-DismCommand {
    param(
        [string]$Arguments,
        [string]$Description
    )
    
    Write-StatusMessage "Executing: $Description" -Type Info
    Write-Host "   (This may take a few minutes...)" -ForegroundColor Gray
    
    try {
        # Use Start-Process for better control
        $process = Start-Process -FilePath "dism.exe" -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        $exitCode = $process.ExitCode
        
        if ($exitCode -eq 0) {
            Write-StatusMessage "$Description completed successfully" -Type Success
            return $true
        } elseif ($exitCode -eq 3010) {
            Write-StatusMessage "$Description completed (reboot required)" -Type Warning
            return $true
        } else {
            Write-StatusMessage "$Description failed with exit code: $exitCode" -Type Error
            return $false
        }
    } catch {
        Write-StatusMessage "Exception during $Description : $($_.Exception.Message)" -Type Error
        return $false
    }
}

function Test-DiskSpace {
    param(
        [string]$Path,
        [int]$RequiredGB = 5
    )
    
    $drive = (Get-Item $Path).PSDrive
    $freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
    
    if ($freeSpaceGB -lt $RequiredGB) {
        Write-StatusMessage "Insufficient disk space on $($drive.Name): (${freeSpaceGB}GB available, ${RequiredGB}GB required)" -Type Error
        return $false
    }
    
    Write-Host "   Available space on $($drive.Name):: ${freeSpaceGB}GB" -ForegroundColor Gray
    return $true
}

function Cleanup-MountPoint {
    if ($script:MountDirInUse -and (Test-Path $MountDir)) {
        Write-StatusMessage "Cleaning up mount point..." -Type Warning
        try {
            dism.exe /Unmount-Image /MountDir:"$MountDir" /Discard | Out-Null
            $script:MountDirInUse = $false
        } catch {
            Write-StatusMessage "Cleanup failed: $($_.Exception.Message)" -Type Error
        }
    }
}

#endregion

#region Main Script

# Script Header
Write-Host "`n"
Write-StatusMessage "======================================================================================================" -Type Header
Write-StatusMessage "  Driver Injection Script for WinPE/OSDCloud      " -Type Header
Write-StatusMessage "======================================================================================================" -Type Header
Write-Host "`n"

# Configuration
$Model = (Get-MyComputerModel)
$Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
$WindowsPath = "C:\"
$MountDir = "C:\Mount\WinRE"
$WinREOutputPath = "C:\OSDCloud\WinRE"
$ReagentcPath = "C:\Windows\System32\reagentc.exe"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SevenZipPath = Join-Path $ScriptRoot "Ressources\7zip\7z.exe"
$DriversFolder = 'C:\OSDCloud\Drivers\'
$DriverFolder = $DriversFolder + $Model
$LogFile = "C:\OSDCloud\Logs\DriverInjection_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$LogDir = Split-Path $LogFile -Parent

# Initialize mount tracking
$script:MountDirInUse = $false

# Register cleanup on script exit
Register-EngineEvent PowerShell.Exiting -Action { Cleanup-MountPoint } | Out-Null

# Setup logging
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogFile -Append
Write-StatusMessage "Logging to: $LogFile" -Type Info

# Validate and display model information
if ([string]::IsNullOrWhiteSpace($Model)) {
    Write-StatusMessage "Could not detect computer model" -Type Error
    $Model = Read-Host "Please enter the computer model manually"
    if ([string]::IsNullOrWhiteSpace($Model)) {
        Write-StatusMessage "Model name is required" -Type Error
        Stop-Transcript
        exit 1
    }
}

Write-Host "   Computer Model: $Model" -ForegroundColor Gray
Write-Host "   Manufacturer: $Manufacturer" -ForegroundColor Gray
Write-Host "`n"

# Validate required tools
Write-StatusMessage "Validating required tools..." -Type Info

if (-not (Test-PathWithError -Path $ReagentcPath -Description "reagentc.exe")) {
    Write-StatusMessage "reagentc.exe is required for WinRE configuration" -Type Error
    Stop-Transcript
    exit 1
}

if (-not (Test-PathWithError -Path $SevenZipPath -Description "7-Zip")) {
    Write-StatusMessage "7-Zip not found. Some operations may fail." -Type Warning
}

#region Step 1: Find Driver Folder
Write-Host "`n"
Write-StatusMessage "Step 1: Searching for driver folder in (OS- or USB-Drive: '\Drivers')(OS-Drive: '\OSDCloud\Drivers\$model')..." -Type Header
Write-StatusMessage "Drivers on USB-Drive or C:\Drivers have priority over OSDCloud folder!" -Type Info

$driverFolder = $null
$usbDrive = $null
$foundDrivers = @()

# First pass: Check for '\Drivers' folder on all drives (prioritized)
Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
    $testPath = Join-Path "$($_.Name):\" "Drivers"
    if (Test-Path $testPath) {
        $driverCount = (Get-ChildItem -Path $testPath -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue).Count
        
        $foundDrivers += [PSCustomObject]@{
            Path = $testPath
            Drive = "$($_.Name):\"
            Count = $driverCount
            Priority = if ($_.Name -ne 'C') { 1 } else { 2 }  # USB drives get higher priority
            Source = if ($_.Name -ne 'C') { "USB" } else { "C:\Drivers" }
        }
    }
}

# Second pass: Check for C:\OSDCloud\Drivers\$model (lowest priority)
$osdCloudPath = "C:\OSDCloud\Drivers\$model"
if (Test-Path $osdCloudPath) {
    $driverCount = (Get-ChildItem -Path $osdCloudPath -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue).Count
    
    $foundDrivers += [PSCustomObject]@{
        Path = $osdCloudPath
        Drive = "C:\"
        Count = $driverCount
        Priority = 3  # Lowest priority
        Source = "OSDCloud"
    }
}

# Select the highest priority driver folder
if ($foundDrivers.Count -gt 0) {
    $selectedDriver = $foundDrivers | Sort-Object Priority | Select-Object -First 1
    $driverFolder = $selectedDriver.Path
    $usbDrive = $selectedDriver.Drive
    
    Write-StatusMessage "Driver folder found on $($selectedDriver.Source):" -Type Success
    Write-Host "   Path: $driverFolder" -ForegroundColor Gray
    Write-Host "   Driver .inf files found: $($selectedDriver.Count)" -ForegroundColor Gray
    
    # Show other available driver sources if any
    if ($foundDrivers.Count -gt 1) {
        Write-Host "`n   Other driver sources available (not used):" -ForegroundColor DarkGray
        $foundDrivers | Where-Object { $_.Path -ne $driverFolder } | ForEach-Object {
            Write-Host "   - $($_.Source): $($_.Path) ($($_.Count) drivers)" -ForegroundColor DarkGray
        }
    }
} else {
    Write-StatusMessage "No 'Drivers' folder found on any drive" -Type Error
    Write-StatusMessage "Ensure USB drive contains a 'Drivers' folder with driver files" -Type Warning
    Write-StatusMessage "Or ensure C:\OSDCloud\Drivers\$model exists" -Type Warning
    Stop-Transcript
    exit 1
}
#endregion

#region Step 2: Validate Windows Installation

Write-Host "`n"
Write-StatusMessage "Step 2: Validating Windows installation..." -Type Header

if (-not (Test-PathWithError -Path "$WindowsPath\Windows" -Description "Windows installation")) {
    Stop-Transcript
    exit 1
}

# Check disk space
if (-not (Test-DiskSpace -Path "C:\" -RequiredGB 5)) {
    Stop-Transcript
    exit 1
}

#endregion

#region Step 3: Inject Drivers to Main Windows Installation

Write-Host "`n"
Write-StatusMessage "Step 3: Injecting drivers to Windows installation..." -Type Header
Write-Host "   Source: $driverFolder" -ForegroundColor Gray
Write-Host "   Target: $WindowsPath" -ForegroundColor Gray
Write-Host ""

$success = Invoke-DismCommand -Arguments "/Image:$WindowsPath /Add-Driver /Driver:`"$driverFolder`" /Recurse /ForceUnsigned" `
                               -Description "Driver injection to Windows"

if (-not $success) {
    Write-StatusMessage "Failed to inject drivers to Windows installation" -Type Error
    $continue = Read-Host "Continue with WinRE injection anyway? (Y/N)"
    if ($continue -ne 'Y') {
        Stop-Transcript
        exit 1
    }
} else {
    # Verify driver installation
    Write-StatusMessage "Verifying installed drivers..." -Type Info
    try {
        $installedDrivers = dism.exe /Image:$WindowsPath /Get-Drivers /Format:Table | Select-String "Published Name" | Measure-Object
        Write-Host "   Total drivers in image: $($installedDrivers.Count)" -ForegroundColor Gray
    } catch {
        Write-StatusMessage "Could not verify drivers" -Type Warning
    }
}

#endregion

#region Step 4: Extract WinRE from ESD

Write-Host "`n"
Write-StatusMessage "Step 4: Preparing WinRE environment..." -Type Header

# Find ESD file
$esdFile = Get-ChildItem -Path "C:\OSDCloud\OS" -Filter "*.esd" -File -ErrorAction SilentlyContinue | 
           Select-Object -First 1 -ExpandProperty FullName

if (-not $esdFile) {
    Write-StatusMessage "No ESD file found in C:\OSDCloud\OS" -Type Error
    Write-StatusMessage "Skipping WinRE driver injection" -Type Warning
    Stop-Transcript
    exit 0
}

Write-StatusMessage "ESD file: $esdFile" -Type Info

# Check if Extract-WinRE.ps1 exists in script directory
$ExtractWinREScript = Join-Path $ScriptRoot "Extract-WinRE.ps1"

if (-not (Test-PathWithError -Path $ExtractWinREScript -Description "Extract-WinRE.ps1 script")) {
    Write-StatusMessage "Skipping WinRE driver injection" -Type Warning
    Stop-Transcript
    exit 0
}

# Extract WinRE
try {
    Write-StatusMessage "Extracting WinRE from ESD..." -Type Info
    & $ExtractWinREScript -EsdPath $esdFile -OutputPath $WinREOutputPath
    
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        throw "Extract-WinRE.ps1 returned exit code: $LASTEXITCODE"
    }
    
    Write-StatusMessage "WinRE extraction completed" -Type Success
} catch {
    Write-StatusMessage "Failed to extract WinRE: $($_.Exception.Message)" -Type Error
    Stop-Transcript
    exit 1
}

#endregion

#region Step 5: Inject Drivers to WinRE

Write-Host "`n"
Write-StatusMessage "Step 5: Injecting drivers to WinRE..." -Type Header

$winREWimPath = Join-Path $WinREOutputPath "WinRE.wim"

if (-not (Test-PathWithError -Path $winREWimPath -Description "WinRE.wim")) {
    Write-StatusMessage "Cannot proceed with WinRE driver injection" -Type Error
    Stop-Transcript
    exit 1
}

# Create mount directory
if (-not (Test-Path $MountDir)) {
    try {
        New-Item -Path $MountDir -ItemType Directory -Force | Out-Null
        Write-StatusMessage "Created mount directory: $MountDir" -Type Success
    } catch {
        Write-StatusMessage "Failed to create mount directory: $($_.Exception.Message)" -Type Error
        Stop-Transcript
        exit 1
    }
}

# Disable ReagentC
Write-StatusMessage "Disabling Windows Recovery Agent..." -Type Info
try {
    $reagentResult = & $ReagentcPath /disable /Target C:\Windows 2>&1
    $reagentExitCode = $LASTEXITCODE
    
    # Exit codes: 0 = success, 2 = already disabled, other = error
    if ($reagentExitCode -eq 0) {
        Write-StatusMessage "Windows Recovery Agent disabled" -Type Success
    } elseif ($reagentExitCode -eq 2) {
        Write-StatusMessage "Windows Recovery Agent was already disabled" -Type Info
    } else {
        Write-StatusMessage "ReagentC warning (Exit code: $reagentExitCode) - continuing anyway" -Type Warning
    }
} catch {
    Write-StatusMessage "Error disabling Recovery Agent: $($_.Exception.Message)" -Type Warning
}

# Mount WinRE
$success = Invoke-DismCommand -Arguments "/Mount-Wim /WimFile:`"$winREWimPath`" /Index:1 /MountDir:`"$MountDir`"" `
                               -Description "Mounting WinRE image"

if (-not $success) {
    Write-StatusMessage "Failed to mount WinRE image" -Type Error
    Stop-Transcript
    exit 1
}

# Mark mount as in use
$script:MountDirInUse = $true

# Inject drivers to WinRE
$success = Invoke-DismCommand -Arguments "/Image:`"$MountDir`" /Add-Driver /Driver:`"$driverFolder`" /Recurse /ForceUnsigned" `
                               -Description "Driver injection to WinRE"

# Cleanup and optimize
if ($success) {
    $success = Invoke-DismCommand -Arguments "/Image:`"$MountDir`" /Cleanup-Image /StartComponentCleanup /ResetBase" `
                                   -Description "WinRE image cleanup and optimization"
}

# Unmount WinRE
$unmountSuccess = Invoke-DismCommand -Arguments "/Unmount-Image /MountDir:`"$MountDir`" /Commit" `
                                      -Description "Unmounting WinRE image"

if ($unmountSuccess) {
    $script:MountDirInUse = $false
} else {
    Write-StatusMessage "Attempting to discard changes and unmount..." -Type Warning
    Invoke-DismCommand -Arguments "/Unmount-Image /MountDir:`"$MountDir`" /Discard" `
                       -Description "Discarding changes and unmounting"
    $script:MountDirInUse = $false
}

# Copy WinRE back and re-enable
$targetWinREPath = "C:\Windows\System32\Recovery\WinRE.wim"

try {
    Write-StatusMessage "Copying WinRE.wim to system directory..." -Type Info
    
    # Ensure target directory exists
    $targetDir = Split-Path $targetWinREPath -Parent
    if (-not (Test-Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }
    
    Copy-Item -Path $winREWimPath -Destination $targetWinREPath -Force
    Write-StatusMessage "WinRE.wim copied successfully" -Type Success
} catch {
    Write-StatusMessage "Failed to copy WinRE.wim: $($_.Exception.Message)" -Type Error
    Stop-Transcript
    exit 1
}

# Re-enable ReagentC
Write-StatusMessage "Re-enabling Windows Recovery Agent..." -Type Info
try {
    $reagentResult = & $ReagentcPath /enable /Target C:\Windows 2>&1
    $reagentExitCode = $LASTEXITCODE
    
    if ($reagentExitCode -eq 0) {
        Write-StatusMessage "Windows Recovery Agent enabled" -Type Success
    } else {
        Write-StatusMessage "Failed to enable Windows Recovery Agent (Exit code: $reagentExitCode)" -Type Warning
    }
} catch {
    Write-StatusMessage "Error enabling Recovery Agent: $($_.Exception.Message)" -Type Warning
}

#endregion

#region Completion

Write-Host "`n"
Write-StatusMessage "======================================================================================================" -Type Header
Write-StatusMessage "  Driver injection completed successfully!        " -Type Header
Write-StatusMessage "======================================================================================================" -Type Header
Write-Host "`n"

Write-StatusMessage "Log file saved to: $LogFile" -Type Info

Stop-Transcript

#endregion