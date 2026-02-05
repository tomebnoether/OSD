#to Run, boot OSDCloudUSB, at the PS Prompt: iex (irm https://raw.githubusercontent.com/tomebnoether/OSD/refs/heads/main/Start-OSD2.ps1)

#region Initialization
function Write-DarkGrayDate {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [System.String]
        $Message
    )
    if ($Message) {
        Write-Host -ForegroundColor DarkGray "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) $Message"
    }
    else {
        Write-Host -ForegroundColor DarkGray "$((Get-Date).ToString('yyyy-MM-dd-HHmmss')) " -NoNewline
    }
}
function Write-DarkGrayHost {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.String]
        $Message
    )
    Write-Host -ForegroundColor DarkGray $Message
}
function Write-DarkGrayLine {
    [CmdletBinding()]
    param ()
    Write-Host -ForegroundColor DarkGray '========================================================================='
}
function Write-SectionHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.String]
        $Message
    )
    Write-DarkGrayLine
    Write-DarkGrayDate
    Write-Host -ForegroundColor Cyan $Message
}
function Write-SectionSuccess {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [System.String]
        $Message = 'Success!'
    )
    Write-DarkGrayDate
    Write-Host -ForegroundColor Green $Message
}
#endregion

$ScriptName = 'https://raw.githubusercontent.com/tomebnoether/OSD/refs/heads/main/Start-OSD.ps1'
$ScriptVersion = '26.02.04.02'
Write-Host -ForegroundColor Green "$ScriptName $ScriptVersion"
#iex (irm functions.garytown.com) #Add custom functions used in Script Hosting in GitHub
#iex (irm functions.osdcloud.com) #Add custom fucntions from OSDCloud

<# Offline Driver Details
If you extract Driver Packs to your Flash Drive, you can DISM them in while in WinPE and it will make the process much faster, plus ensure driver support for first Boot
Extract to: OSDCLoudUSB:\OSDCloud\DriverPacks\DISM\$ComputerManufacturer\$ComputerProduct
Use OSD Module to determine Vars
$ComputerProduct = (Get-MyComputerProduct)
$ComputerManufacturer = (Get-MyComputerManufacturer -Brief)
#>

#Variables to define the Windows OS / Edition etc to be applied during OSDCloud
$Product = (Get-MyComputerProduct)
$Model = (Get-MyComputerModel)
$Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
$OSVersion = 'Windows 11' #Used to Determine Driver Pack
$OSReleaseID = '25H2' #Used to Determine Driver Pack
$OSName = 'Windows 11 25H2 x64'
$OSEdition = 'Pro'
$OSActivation = 'Retail'
$OSLanguage = 'de-de'

#Variables to define for custom Driver-Installation
$GitHubAccount = 'tomebnoether'
$GitHubRepo = 'OSD'
$GitHubTree = 'main'
$GitHubDriverFolderName = 'Drivers'
$ModelShortened = $Model -replace '\s','%20'
$RepoURL = 'https://github.com/' + $GitHubAccount + '/' + $GitHubRepo + '/raw/refs/heads/' + $GitHubTree + '/' + $GitHubDriverFolderName + '/' + $Manufacturer + '/' + $ModelShortened + '.zip'
$RepoURL = '"' + $repourl + '"'
$DriversFolder = 'C:\OSDCloud\Drivers\'
$DriverZip = $DriversFolder + $model + '.zip'
$DriverFolder = $DriversFolder + $Model

#Set OSDCloud Vars
$Global:MyOSDCloud = [ordered]@{
    Restart = [bool]$False
    RecoveryPartition = [bool]$true
    OEMActivation = [bool]$True
    WindowsUpdate = [bool]$true
    WindowsUpdateDrivers = [bool]$true
    WindowsDefenderUpdate = [bool]$true
    SetTimeZone = [bool]$true
    ClearDiskConfirm = [bool]$False
    ShutdownSetupComplete = [bool]$false
    SyncMSUpCatDriverUSB = [bool]$false
    CheckSHA1 = [bool]$true
}


$Global:MyOSDCloud.DriverPackName = 'none'

#Used to Determine Driver Pack
$DriverPack = Get-OSDCloudDriverPack -Product $Product -OSVersion $OSVersion -OSReleaseID $OSReleaseID

if ($DriverPack){
    $Global:MyOSDCloud.DriverPackName = $DriverPack.Name
}


#Search for Drivers on USB or on GitHub Repo
if (Test-DISMFromOSDCloudUSB){
    Write-Host "Found Driver Pack Extracted on Cloud USB Flash Drive, disabling Driver Download via OSDCloud" -ForegroundColor Green
    if ($Global:MyOSDCloud.SyncMSUpCatDriverUSB -eq $true){
        Write-Host "Setting DriverPackName to 'Microsoft Update Catalog'" -ForegroundColor Cyan
        $Global:MyOSDCloud.DriverPackName = 'Microsoft Update Catalog'
    }
    else {
        # Create drivers folder if it doesn't exist
        if (-not (Test-Path $DriversFolder)) {
            New-Item -Path $DriversFolder -ItemType Directory -Force | Out-Null
        }
        
        # Try to download drivers from GitHub
        try {
            Write-Host "Attempting to download drivers from GitHub repository..." -ForegroundColor Cyan
            Write-Host "URL: $RepoURL" -ForegroundColor Gray
            
            # Download the driver zip file
            Invoke-WebRequest -Uri $RepoURL.Trim('"') -OutFile $DriverZip -ErrorAction Stop
            
            Write-Host "Found Driver Pack on GitHub-Repo, disabling Driver Download via OSDCloud" -ForegroundColor Green
            
            # Extract drivers
            Expand-Archive -Path $DriverZip -DestinationPath $DriverFolder -Force
            Remove-Item $DriverZip -Force -ErrorAction SilentlyContinue
            
            Write-Host "Drivers extracted to: $DriverFolder" -ForegroundColor Green
        }
        catch {
            Write-Host "Could not download drivers from GitHub: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Will rely on OSDCloud driver pack or manual driver installation" -ForegroundColor Yellow
        }
        
        Write-Host "Setting DriverPackName to 'None'" -ForegroundColor Cyan
        $Global:MyOSDCloud.DriverPackName = "None"
    }
}

#Write variables to console
Write-SectionHeader "OSDCloud Variables"
Write-Output $Global:MyOSDCloud

#Launch OSDCloud
Write-SectionHeader -Message "Starting OSDCloud"
Write-Host "Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage" -ForegroundColor Gray

Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage

Write-SectionHeader -Message "OSDCloud Process Complete, Running Custom Actions From Script Before Reboot"

#region Post Deployment Tasks

#Driver installation - FIXED: Call the correct driver injection script
Write-SectionHeader -Message "Starting Driver Injection Process"

try {
    # Download and execute the driver injection script
    $DriverInjectionScriptURL = "https://raw.githubusercontent.com/$GitHubAccount/$GitHubRepo/refs/heads/$GitHubTree/Driver-Injection.ps1"
    
    Write-Host "Downloading driver injection script from: $DriverInjectionScriptURL" -ForegroundColor Cyan
    
    # Download the script to a temporary location
    $TempDriverScript = "C:\OSDCloud\Driver-Injection.ps1"
    Invoke-WebRequest -Uri $DriverInjectionScriptURL -OutFile $TempDriverScript -ErrorAction Stop
    
    Write-Host "Executing driver injection script..." -ForegroundColor Cyan
    
    # Execute the script
    & $TempDriverScript
    
    if ($LASTEXITCODE -eq 0) {
        Write-SectionSuccess "Driver injection completed successfully"
    } else {
        Write-Host "Driver injection script returned exit code: $LASTEXITCODE" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error during driver injection: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Continuing with deployment..." -ForegroundColor Yellow
}


#Copy CMTrace Local:
if (Test-Path -Path "x:\windows\system32\cmtrace.exe"){
    Copy-Item "x:\windows\system32\cmtrace.exe" -Destination "C:\Windows\System32\cmtrace.exe" -Verbose
}

#endregion

#region Deployment Summary
Write-Host "`n"
Write-SectionHeader -Message "Deployment Summary"
Write-Host "`n"

# System Information
Write-Host "SYSTEM INFORMATION" -ForegroundColor Cyan
Write-Host "  Manufacturer: " -NoNewline -ForegroundColor Gray
Write-Host "$Manufacturer" -ForegroundColor White
Write-Host "  Model: " -NoNewline -ForegroundColor Gray
Write-Host "$Model" -ForegroundColor White
Write-Host "  Product: " -NoNewline -ForegroundColor Gray
Write-Host "$Product" -ForegroundColor White
Write-Host "`n"

# Operating System
Write-Host "OPERATING SYSTEM" -ForegroundColor Cyan
Write-Host "  OS Name: " -NoNewline -ForegroundColor Gray
Write-Host "$OSName" -ForegroundColor White
Write-Host "  Edition: " -NoNewline -ForegroundColor Gray
Write-Host "$OSEdition" -ForegroundColor White
Write-Host "  Language: " -NoNewline -ForegroundColor Gray
Write-Host "$OSLanguage" -ForegroundColor White
Write-Host "  Activation: " -NoNewline -ForegroundColor Gray
Write-Host "$OSActivation" -ForegroundColor White
Write-Host "`n"

# Driver Information
Write-Host "DRIVER INSTALLATION" -ForegroundColor Cyan
if ($Global:MyOSDCloud.DriverPackName -eq "None") {
    if (Test-Path $DriverFolder) {
        Write-Host "  Source: " -NoNewline -ForegroundColor Gray
        Write-Host "Custom Drivers" -ForegroundColor Green
        Write-Host "  Location: " -NoNewline -ForegroundColor Gray
        Write-Host "$DriverFolder" -ForegroundColor White
        
        $driverCount = (Get-ChildItem -Path $DriverFolder -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue).Count
        Write-Host "  Driver Files: " -NoNewline -ForegroundColor Gray
        Write-Host "$driverCount .inf files" -ForegroundColor White
    } else {
        Write-Host "  Source: " -NoNewline -ForegroundColor Gray
        Write-Host "No custom drivers" -ForegroundColor Yellow
    }
} elseif ($Global:MyOSDCloud.DriverPackName -eq "Microsoft Update Catalog") {
    Write-Host "  Source: " -NoNewline -ForegroundColor Gray
    Write-Host "Microsoft Update Catalog" -ForegroundColor Green
} else {
    Write-Host "  Driver Pack: " -NoNewline -ForegroundColor Gray
    Write-Host "$($Global:MyOSDCloud.DriverPackName)" -ForegroundColor Green
}
Write-Host "`n"

# Updates Applied
Write-Host "UPDATES & CONFIGURATION" -ForegroundColor Cyan
Write-Host "  Windows Updates: " -NoNewline -ForegroundColor Gray
if ($Global:MyOSDCloud.WindowsUpdate) {
    Write-Host "Applied" -ForegroundColor Green
} else {
    Write-Host "Skipped" -ForegroundColor Yellow
}

Write-Host "  Windows Update Drivers: " -NoNewline -ForegroundColor Gray
if ($Global:MyOSDCloud.WindowsUpdateDrivers) {
    Write-Host "Applied" -ForegroundColor Green
} else {
    Write-Host "Skipped" -ForegroundColor Yellow
}

Write-Host "  Windows Defender Update: " -NoNewline -ForegroundColor Gray
if ($Global:MyOSDCloud.WindowsDefenderUpdate) {
    Write-Host "Applied" -ForegroundColor Green
} else {
    Write-Host "Skipped" -ForegroundColor Yellow
}

Write-Host "  OEM Activation: " -NoNewline -ForegroundColor Gray
if ($Global:MyOSDCloud.OEMActivation) {
    Write-Host "Enabled" -ForegroundColor Green
} else {
    Write-Host "Disabled" -ForegroundColor Yellow
}

Write-Host "  Recovery Partition: " -NoNewline -ForegroundColor Gray
if ($Global:MyOSDCloud.RecoveryPartition) {
    Write-Host "Created" -ForegroundColor Green
} else {
    Write-Host "Not Created" -ForegroundColor Yellow
}

Write-Host "  Time Zone: " -NoNewline -ForegroundColor Gray
if ($Global:MyOSDCloud.SetTimeZone) {
    Write-Host "Configured" -ForegroundColor Green
} else {
    Write-Host "Not Configured" -ForegroundColor Yellow
}
Write-Host "`n"

# Additional Tools
Write-Host "ADDITIONAL TOOLS" -ForegroundColor Cyan
if (Test-Path "C:\Windows\System32\cmtrace.exe") {
    Write-Host "  CMTrace: " -NoNewline -ForegroundColor Gray
    Write-Host "Installed" -ForegroundColor Green
} else {
    Write-Host "  CMTrace: " -NoNewline -ForegroundColor Gray
    Write-Host "Not Available" -ForegroundColor DarkGray
}
Write-Host "`n"

# Log File Location
if (Test-Path "C:\OSDCloud\Logs") {
    $logFiles = Get-ChildItem -Path "C:\OSDCloud\Logs" -Filter "*.log" -ErrorAction SilentlyContinue
    if ($logFiles) {
        Write-Host "LOG FILES" -ForegroundColor Cyan
        Write-Host "  Location: " -NoNewline -ForegroundColor Gray
        Write-Host "C:\OSDCloud\Logs" -ForegroundColor White
        Write-Host "  Files: " -NoNewline -ForegroundColor Gray
        Write-Host "$($logFiles.Count) log file(s)" -ForegroundColor White
        Write-Host "`n"
    }
}

Write-DarkGrayLine
Write-Host "`n"
#endregion

Write-SectionHeader -Message "All Post-Deployment Tasks Complete"

#Restart
Write-Host "`nReady to restart computer" -ForegroundColor Green
Write-Host "Press any key to restart or Ctrl+C to cancel..." -ForegroundColor Yellow
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
Restart-Computer
