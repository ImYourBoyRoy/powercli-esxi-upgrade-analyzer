<#
.SYNOPSIS
    ESXi-Upgrade-ReadinessCheck.ps1 - Comprehensive ESXi host upgrade readiness assessment tool

.DESCRIPTION
    Performs a detailed analysis of ESXi hosts to determine their readiness for upgrading to a target ESXi version.
    This script evaluates multiple critical factors including:

    - CPU compatibility with target ESXi version
    - Storage capacity and configuration
    - Current ESXi version and upgrade path requirements
    - Overall system readiness

    The results are presented in both a detailed CSV file and an interactive HTML report that clearly
    categorizes hosts as:

    - Ready for Upgrade: Hosts that meet all requirements for direct upgrade
    - Already Up-To-Date: Hosts already running the target version or latest build
    - Not Ready: Hosts with specific issues preventing upgrade (with detailed explanations)
    - Failed to Check: Hosts that could not be properly assessed (with error details)

    The HTML report includes filtering capabilities, detailed host information, and visual indicators
    to help plan and prioritize your ESXi upgrade strategy.

.PARAMETER Help
    Displays this help message.

.PARAMETER Servers
    One or more server hostnames or IP addresses to check.
    Example: -Servers "esxi01.domain.com","esxi02.domain.com"

.PARAMETER ServerListFile
    Path to a CSV file containing a list of servers. The script looks for a column named "Host Name" 
    or any valid alias (e.g., hostname, host) to find ESXi hosts. Optionally can include an IP column
    under "IP", "IPAddress", or "IP Address".
    Example: -ServerListFile "C:\Inventory\servers.csv"

.PARAMETER NameMatch
    Optional string used to filter servers by partial hostname match (e.g., only include servers with "ESX" or "LAB").
    If not specified, all valid rows are processed.
    Example: -NameMatch "ESX"

.PARAMETER OutputCsv
    Path to a CSV file where results are saved. 
    Default: "ESXi-Upgrade-Results-[timestamp].csv"

.PARAMETER ReportPath
    Path to save HTML summary report with interactive filtering and detailed host information.
    Default: "ESXi-Upgrade-Report-[timestamp].html"

.PARAMETER UpgradeVersion
    Target ESXi version for upgrade assessment. 
    Default: "8.0.3" (pulls from config.json if not specified)

.PARAMETER Parallel
    Process hosts in parallel using PowerShell jobs for faster execution.
    Recommended for checking large numbers of hosts.

.PARAMETER MaxConcurrentJobs
    Maximum number of concurrent jobs when using parallel processing.
    Default: 5

.EXAMPLE
    PS> .\ESXi-Upgrade-ReadinessCheck.ps1 -Servers "esxi01.domain.com","esxi02.domain.com" -OutputCsv "results.csv"
    
    Checks the specified servers and saves results to "results.csv"

.EXAMPLE
    PS> .\ESXi-Upgrade-ReadinessCheck.ps1 -ServerListFile "servers.csv" -Parallel -MaxConcurrentJobs 10
    
    Processes all ESXi hosts in the CSV file in parallel with 10 concurrent jobs maximum

.EXAMPLE
    PS> .\ESXi-Upgrade-ReadinessCheck.ps1 -ServerListFile "servers.csv" -NameMatch "CHQ"
    
    Only checks servers whose hostnames contain "CHQ"

.EXAMPLE
    PS> .\ESXi-Upgrade-ReadinessCheck.ps1 -ServerListFile "servers.csv" -UpgradeVersion "8.0.3"
    
    Assesses all hosts against ESXi 8.0.3 requirements specifically

.NOTES
    Author: Roy Dawson IV
    Github: https://github.com/ImYourBoyRoy
    Version: 2.1
    Last Updated: April 2025

    REQUIREMENTS:
    - VMware PowerCLI
    - Configuration is read from config.json in the same folder (optional)

    CONFIG.JSON FORMAT:
    {
        "Username": "user@domain.com",
        "Password": "SecurePassword",
        "TargetESXiVersion": "8.0.3",
        "MinimumRequiredSpaceGB": 10,
        "MinimumBootbankFreePercentage": 90
    }

    FEATURES:
    - Precise version and build identification
    - Detailed CPU compatibility verification
    - Storage requirement validation
    - Upgrade path determination
    - Categorized reporting with actionable recommendations
    - Interactive HTML report with filtering capabilities
    - Multi-threaded processing for large environments
    - Comprehensive logging and error tracking
#>

[CmdletBinding()]
param (
    [switch]$Help,
    [string[]]$Servers,
    [string]$ServerListFile,
    [string]$OutputCsv = "ESXi-Upgrade-Results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [string]$ReportPath = "ESXi-Upgrade-Report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html",
    [string]$UpgradeVersion,
    [switch]$Parallel,
    [int]$MaxConcurrentJobs = 5,
    [string]$NameMatch
)

#region Script Initialization and Setup

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:GlobalConfig = $null
$script:PowerCLIConfigured = $false
$script:Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$script:LogFile = "ESXi-Upgrade-Log-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:FailureLogFile = "ESXi-Upgrade-Failures-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$script:Summary = @{
    TotalHosts = 0
    ReadyForUpgrade = 0
    NotReadyForUpgrade = 0
    FailedToCheck = 0
    AlreadyUpToDate = 0
    Categories = @{
        "Ready" = @()
        "CPU Incompatible" = @()
        "Storage Issues" = @()
        "Requires Intermediate Upgrade" = @() 
        "Multiple Issues" = @()
        "Failed to Check" = @()
        "Already Up-To-Date" = @()
    }
}

# Display help if requested or if no parameters provided
if ($Help -or (-not $Servers -and -not $ServerListFile)) {
    $helpText = @"
ESXi Upgrade Readiness Assessment Tool
======================================

USAGE: ESXi-Upgrade-ReadinessCheck.ps1 [-Help] [-Servers <String[]>] [-ServerListFile <String>] 
       [-OutputCsv <String>] [-ReportPath <String>] [-UpgradeVersion <String>] [-Parallel] [-MaxConcurrentJobs <Int>]

DESCRIPTION:
  Performs a comprehensive ESXi upgrade readiness check with detailed reporting and categorization.
  Clearly identifies which hosts can be upgraded to ESXi 8.x and why others cannot.

PARAMETERS:
  -Help                 Displays this help message.
  -Servers              One or more server hostnames/IPs.
  -ServerListFile       Path to a CSV file with a 'Host Name' column for ESXi hosts.
  -OutputCsv            Path to save CSV results. Default: "ESXi-Upgrade-Results-[timestamp].csv"
  -ReportPath           Path to save HTML report. Default: "ESXi-Upgrade-Report-[timestamp].html"
  -UpgradeVersion       Target ESXi version. Default: "8.0.3" (or value from config.json)
  -Parallel             Process hosts in parallel for faster execution.
  -MaxConcurrentJobs    Maximum concurrent jobs when using parallel processing. Default: 5

EXAMPLES:
  .\ESXi-Upgrade-ReadinessCheck.ps1 -Servers "esxi01.domain.com","esxi02.domain.com"
  .\ESXi-Upgrade-ReadinessCheck.ps1 -ServerListFile "servers.csv" -Parallel -MaxConcurrentJobs 10
"@
    Write-Host $helpText -ForegroundColor Cyan
    return
}

#endregion

#region Helper Functions

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO',
        [switch]$JobContext
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colorMap = @{
        'INFO' = 'White'
        'WARNING' = 'Yellow'
        'ERROR' = 'Red'
        'SUCCESS' = 'Green'
    }
    
    # Format the message
    $formattedMessage = "[$timestamp] [$Level]"
    if ($JobContext) {
        $formattedMessage += " [Job]"
    }
    $formattedMessage += " $Message"
    
    # Console output with appropriate color
    Write-Host $formattedMessage -ForegroundColor $colorMap[$Level]
    
    # Only write to log file if not in job context
    if (-not $JobContext -and $script:LogFile) {
        $formattedMessage | Out-File -FilePath $script:LogFile -Append
    }
}

function Write-FailureLog {
    param (
        [string]$HostName,
        [string]$Reason,
        [string]$IPAddress = "",
        [switch]$JobContext
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp - Failed to process host: $HostName"
    if ($IPAddress) {
        $logEntry += " (IP: $IPAddress)"
    }
    $logEntry += " - Reason: $Reason"
    
    # Only write to failure log file if not in job context
    if (-not $JobContext -and $script:FailureLogFile) {
        $logEntry | Out-File -FilePath $script:FailureLogFile -Append
    }
    
    # Also write to main log
    Write-Log -Message "Failed to process host: $HostName - Reason: $Reason" -Level 'ERROR' -JobContext:$JobContext
}

function Initialize-Summary {
    $script:Summary.TotalHosts = 0
    $script:Summary.ReadyForUpgrade = 0
    $script:Summary.NotReadyForUpgrade = 0
    $script:Summary.FailedToCheck = 0
    $script:Summary.AlreadyUpToDate = 0
    $script:Summary.Categories = @{
        "Ready" = @()
        "CPU Incompatible" = @()
        "Storage Issues" = @()
        "Requires Intermediate Upgrade" = @()
        "Multiple Issues" = @()
        "Failed to Check" = @()
        "Already Up-To-Date" = @()
    }
}

function Format-ByteSize {
    param ([double]$Bytes)
    $sizes = 'Bytes,KB,MB,GB,TB,PB'
    $sizes = $sizes.Split(',')
    $index = 0
    while ($Bytes -ge 1024 -and $index -lt ($sizes.Count - 1)) {
        $Bytes = $Bytes / 1024
        $index++
    }
    return "{0:N2} {1}" -f $Bytes, $sizes[$index]
}

function Write-ProgressUpdate {
    param (
        [int]$Current,
        [int]$Total,
        [string]$Status
    )
    
    $percentComplete = [math]::Round(($Current / $Total) * 100, 2)
    Write-Progress -Activity "ESXi Upgrade Readiness Assessment" -Status $Status -PercentComplete $percentComplete
}

#endregion

#region Configuration and Setup

function Get-Configuration {
    if (-not $script:GlobalConfig) {
        try {
            $configPath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
            
            if (Test-Path -Path $configPath) {
                $json = Get-Content -Path $configPath -Raw | ConvertFrom-Json
                Write-Log -Message "Configuration loaded successfully from $configPath" -Level 'INFO'
                
                # Convert Username/Password to PSCredential
                $securePassword = ConvertTo-SecureString $json.Password -AsPlainText -Force
                $creds = New-Object System.Management.Automation.PSCredential($json.Username, $securePassword)
                
                # Use parameter value if provided, otherwise use config value
                $targetVersion = if ($UpgradeVersion) { $UpgradeVersion } else { $json.TargetESXiVersion }
                
                # Create properties with safe access to potentially missing properties
                $script:GlobalConfig = [PSCustomObject]@{
                    Credential = $creds
                    TargetESXiVersion = $targetVersion
                    TargetESXiBuild = "24674464"  # Updated to include latest build
                    TargetESXiDetail = "ESXi 8.0.3 Update 3e (Build 24674464)"  # Added target version detail
                    MinimumRequiredSpaceGB = if ((Get-Member -InputObject $json -Name 'MinimumRequiredSpaceGB' -MemberType Properties)) { $json.MinimumRequiredSpaceGB } else { 16 }
                    MinimumBootbankFreePercentage = if ((Get-Member -InputObject $json -Name 'MinimumBootbankFreePercentage' -MemberType Properties)) { $json.MinimumBootbankFreePercentage } else { 90 }
                    VendorModelsSupported = if ((Get-Member -InputObject $json -Name 'VendorModelsSupported' -MemberType Properties)) { $json.VendorModelsSupported } else { @() }
                }
            }
            else {
                # If config file doesn't exist, prompt for credentials
                Write-Log -Message "Config file not found at $configPath, prompting for credentials" -Level 'WARNING'
                $creds = Get-Credential -Message "Enter credentials for ESXi hosts"
                
                # Use parameter value if provided, otherwise use default
                $targetVersion = if ($UpgradeVersion) { $UpgradeVersion } else { "8.0.3" }
                
                $script:GlobalConfig = [PSCustomObject]@{
                    Credential = $creds
                    TargetESXiVersion = $targetVersion
                    TargetESXiBuild = "24674464"  # Latest build
                    TargetESXiDetail = "ESXi 8.0.3 Update 3e (Build 24674464)"
                    MinimumRequiredSpaceGB = 16
                    MinimumBootbankFreePercentage = 90
                    VendorModelsSupported = @()
                }
            }
        }
        catch {
            Write-Log -Message "Failed to load configuration: $_" -Level 'ERROR'
            throw "Failed to load configuration: $_"
        }
    }
    
    return $script:GlobalConfig
}

function Initialize-PowerCLI {
    if (-not $script:PowerCLIConfigured) {
        try {
            # Test if PowerCLI is installed
            $powerCLIModule = Get-Module -Name VMware.PowerCLI -ListAvailable
            if (-not $powerCLIModule) {
                Write-Log -Message "VMware PowerCLI module not found. Please install it using: Install-Module -Name VMware.PowerCLI -Scope CurrentUser" -Level 'ERROR'
                throw "VMware PowerCLI module not found."
            }
            
            # Import VMware modules if not already imported
            $requiredModules = @(
                'VMware.VimAutomation.Core', 
                'VMware.VimAutomation.Common'
            )
            
            foreach ($module in $requiredModules) {
                if (-not (Get-Module -Name $module)) {
                    Write-Log -Message "Importing module: $module" -Level 'INFO'
                    Import-Module -Name $module -ErrorAction Stop
                }
            }
            
            # Configure PowerCLI settings
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
            
            Write-Log -Message "PowerCLI configuration set successfully" -Level 'SUCCESS'
            $script:PowerCLIConfigured = $true
        }
        catch {
            Write-Log -Message "Failed to initialize PowerCLI: $_" -Level 'ERROR'
            throw "Failed to initialize PowerCLI: $_"
        }
    }
}

#endregion

#region Host Analysis Functions

function Connect-ESXiHost {
    param (
        [string]$HostName,
        [PSCredential]$Credential,
        [string]$IPAddress = ""
    )
    
    try {
        Write-Log -Message "Attempting connection to host: $HostName" -Level 'INFO'
        
        # Try hostname first
        try {
            $server = Connect-VIServer -Server $HostName -Credential $Credential -ErrorAction Stop
            # Make sure we're returning a single server
            if ($server -is [Array]) {
                $server = $server[0]
            }
            Write-Log -Message "Connected to ESXi host $($server.Name)" -Level 'SUCCESS'
            return $server
        }
        catch {
            # If hostname fails and IP is provided, try IP address
            if ($IPAddress) {
                Write-Log -Message "Failed to connect using hostname, trying IP address: $IPAddress" -Level 'WARNING'
                $server = Connect-VIServer -Server $IPAddress -Credential $Credential -ErrorAction Stop
                # Make sure we're returning a single server
                if ($server -is [Array]) {
                    $server = $server[0]
                }
                Write-Log -Message "Connected to ESXi host $($server.Name) via IP: $IPAddress" -Level 'SUCCESS'
                return $server
            }
            else {
                throw $_
            }
        }
    }
    catch {
        Write-FailureLog -HostName $HostName -IPAddress $IPAddress -Reason $_.Exception.Message
        return $null
    }
}

function Get-ESXiHostInfo {
    param(
        [string]$HostName,
        [object]$Server
    )
    
    try {
        # Make sure Server is a single VMHost object
        if ($Server -is [Array]) {
            # If an array is returned, take the first item
            $Server = $Server[0]
            Write-Log -Message "Server returned as array, using first item" -Level 'WARNING'
        }
        
		Write-Log -Message "Getting host information for ${HostName}" -Level 'INFO'
        # Get VMHost object
        $vmhost = Get-VMHost -Name $HostName -Server $Server -ErrorAction Stop
        
        Write-Log -Message "Retrieved host information for ${HostName}: Version $($vmhost.Version), Build $($vmhost.Build)" -Level 'INFO'
        return $vmhost
    }
    catch {
        Write-Log -Message "Failed to retrieve host information for ${HostName}: $_" -Level 'ERROR'
        throw $_
    }
}

function Get-ESXiImageProfile {
    param (
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )
    
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2
        $profileResult = $esxcli.software.profile.get.Invoke()
        
        if ($profileResult) {
            return $profileResult.Name
        }
        else {
            Write-Log -Message "Unable to retrieve image profile for host $($VMHost.Name)" -Level 'WARNING'
            return "Unknown"
        }
    }
    catch {
        Write-Log -Message "Failed to retrieve image profile for host $($VMHost.Name): $_" -Level 'WARNING'
        return "Unknown"
    }
}

function Get-ESXiInstallDate {
    param (
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )
    
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2
        $installDate = ($esxcli.software.vib.list.Invoke() | Where-Object { $_.Name -match "esx-base" }).InstallDate
        
        if ($installDate) {
            return $installDate
        }
        else {
            Write-Log -Message "Unable to retrieve install date for host $($VMHost.Name)" -Level 'WARNING'
            return "Unknown"
        }
    }
    catch {
        Write-Log -Message "Failed to retrieve install date for host $($VMHost.Name): $_" -Level 'WARNING'
        return "Unknown"
    }
}

function Get-ESXiSystemTime {
    param (
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )
    
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2
        $timeInfo = $esxcli.system.time.get.Invoke()
        
        if ($timeInfo) {
            return $timeInfo
        }
        else {
            Write-Log -Message "Unable to retrieve system time for host $($VMHost.Name)" -Level 'WARNING'
            return "Unknown"
        }
    }
    catch {
        Write-Log -Message "Failed to retrieve system time for host $($VMHost.Name): $_" -Level 'WARNING'
        return "Unknown"
    }
}

function Get-ESXiFilesystemInfo {
    param (
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )
    
    try {
        $esxcli = Get-EsxCli -VMHost $VMHost -V2
        $filesystemInfo = $esxcli.storage.filesystem.list.Invoke()
        
        $volumeInfo = @()
        foreach ($volume in $filesystemInfo) {
            # Ensure size is a number (some versions of ESXi may return strings)
            [double]$sizeBytes = if ($volume.Size -is [string]) { [double]::Parse($volume.Size) } else { $volume.Size }
            [double]$freeBytes = if ($volume.Free -is [string]) { [double]::Parse($volume.Free) } else { $volume.Free }
            
            $totalSizeGB = [math]::Round($sizeBytes / 1GB, 2)
            $freeSpaceGB = [math]::Round($freeBytes / 1GB, 2)
            $usedSpaceGB = [math]::Round($totalSizeGB - $freeSpaceGB, 2)
            $percentFree = if ($totalSizeGB -gt 0) { [math]::Round(($freeSpaceGB / $totalSizeGB) * 100, 2) } else { 0 }
            
            $volumeInfo += [PSCustomObject]@{
                VolumeName = $volume.VolumeName
                MountPoint = $volume.MountPoint
                Type = $volume.Type
                UUID = $volume.UUID
                TotalSizeGB = $totalSizeGB
                FreeSpaceGB = $freeSpaceGB
                UsedSpaceGB = $usedSpaceGB
                PercentFree = $percentFree
            }
        }
        
        Write-Log -Message "Retrieved filesystem information for host $($VMHost.Name)" -Level 'INFO'
        return $volumeInfo
    }
    catch {
        Write-Log -Message "Failed to retrieve filesystem information for host $($VMHost.Name): $_" -Level 'ERROR'
        return $null
    }
}

function Get-ESXiHardwareInfo {
    param (
        [Parameter(Mandatory = $true)]
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )
    
    try {
        $view = Get-View $VMHost
        $hardware = $view.Hardware
        $assetTag = Get-ESXiAssetTag -VMHost $VMHost
        
        $hardwareInfo = [PSCustomObject]@{
            AssetTag = if ($assetTag) { $assetTag } else { "Unknown" }
            SerialNumber = $hardware.SystemInfo.SerialNumber
            BiosVersion = $hardware.BiosInfo.BiosVersion
            BiosReleaseDate = $hardware.BiosInfo.ReleaseDate
            Manufacturer = $hardware.SystemInfo.Vendor
            Model = $hardware.SystemInfo.Model
            LogicalProcessors = $hardware.CpuInfo.NumCpuThreads
            ProcessorType = $VMHost.ProcessorType
            Sockets = $hardware.CpuInfo.NumCpuPackages
            CoresPerSocket = $hardware.CpuInfo.NumCpuCores
            MemoryGB = [math]::Round($hardware.MemorySize / 1GB, 2)
        }
        
        Write-Log -Message "Retrieved hardware information for host $($VMHost.Name)" -Level 'INFO'
        return $hardwareInfo
    }
    catch {
        Write-Log -Message "Failed to retrieve hardware information for host $($VMHost.Name): $_" -Level 'ERROR'
        return $null
    }
}

function Get-ESXiAssetTag {
    param (
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )
    
    try {
        $otherInfo = $VMHost.ExtensionData.Summary.Hardware.OtherIdentifyingInfo
        $assetTag = $otherInfo | Where-Object { $_.IdentifierValue -match "^[A-Z0-9]{7,}" } | Select-Object -First 1
        
        if ($assetTag) {
            return $assetTag.IdentifierValue
        }
        else {
            return "Unknown"
        }
    }
    catch {
        Write-Log -Message "Failed to retrieve asset tag for host $($VMHost.Name): $_" -Level 'WARNING'
        return "Unknown"
    }
}

function Get-ESXiNetworkInfo {
    param (
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VMHost]$VMHost
    )
    
    try {
        $networkSystem = Get-View $VMHost.ExtensionData.ConfigManager.NetworkSystem
        $dnsConfig = $networkSystem.DnsConfig
        $ipRouteConfig = $networkSystem.IpRouteConfig
        
        $vmkernelAdapters = Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel
        $physicalAdapters = Get-VMHostNetworkAdapter -VMHost $VMHost -Physical
        
        # Fix DNS server formatting
        $dnsServers = @()
        if ($dnsConfig.Address) {
            $dnsServers = $dnsConfig.Address | ForEach-Object { $_.ToString() }
        }
        
        $networkInfo = [PSCustomObject]@{
            Hostname = $VMHost.Name
            IPAddresses = $vmkernelAdapters | ForEach-Object { "$($_.Name): $($_.IP)" }
            DNSServers = $dnsServers
            DefaultGateway = $ipRouteConfig.DefaultGateway
            HostAdapters = $physicalAdapters.Count
            IPv6Enabled = $VMHost.ExtensionData.Config.Network.Ipv6Enabled
        }
        
        Write-Log -Message "Retrieved network information for host $($VMHost.Name)" -Level 'INFO'
        return $networkInfo
    }
    catch {
        Write-Log -Message "Failed to retrieve network information for host $($VMHost.Name): $_" -Level 'ERROR'
        return $null
    }
}

function Get-ESXiReleaseInfo {
    param (
        [Parameter(Mandatory = $true)]
        [string]$BuildNumber
    )
    
    $buildNumber = $BuildNumber.Trim()
    
    # ESXi 8.0.x release mapping
    $esxi8Releases = @{
        "24674464" = @{ Version = "8.0.3"; ReleaseName = "ESXi 8.0 Update 3e (P05)"; ReleaseDate = "2025/04/10"; LatestStable = $true }
        "24585383" = @{ Version = "8.0.3"; ReleaseName = "ESXi 8.0 Update 3d"; ReleaseDate = "2025/03/04"; LatestStable = $false }
        "24585300" = @{ Version = "8.0.2"; ReleaseName = "ESXi 8.0 Update 2d"; ReleaseDate = "2025/03/04"; LatestStable = $false }
        "24414501" = @{ Version = "8.0.3"; ReleaseName = "ESXi 8.0 Update 3c (EP3)"; ReleaseDate = "2024/12/12"; LatestStable = $false }
        "24569005" = @{ Version = "8.0.0"; ReleaseName = "ESXi 8.0e"; ReleaseDate = "2025/03/11"; LatestStable = $false }
        "24280767" = @{ Version = "8.0.3"; ReleaseName = "ESXi 8.0 Update 3b (P04)"; ReleaseDate = "2024/09/17"; LatestStable = $false }
        "24022510" = @{ Version = "8.0.3"; ReleaseName = "ESXi 8.0 Update 3"; ReleaseDate = "2024/06/25"; LatestStable = $false }
        "23825572" = @{ Version = "8.0.2"; ReleaseName = "ESXi 8.0 Update 2c (EP2)"; ReleaseDate = "2024/05/21"; LatestStable = $false }
        "23299997" = @{ Version = "8.0.1"; ReleaseName = "ESXi 8.0 Update 1d"; ReleaseDate = "2024/03/05"; LatestStable = $false }
        "23305546" = @{ Version = "8.0.2"; ReleaseName = "ESXi 8.0 Update 2b (P03)"; ReleaseDate = "2024/02/29"; LatestStable = $false }
        "22380479" = @{ Version = "8.0.2"; ReleaseName = "ESXi 8.0 Update 2"; ReleaseDate = "2023/09/21"; LatestStable = $false }
        "22088125" = @{ Version = "8.0.1"; ReleaseName = "ESXi 8.0 Update 1c (P02)"; ReleaseDate = "2023/07/27"; LatestStable = $false }
        "21813344" = @{ Version = "8.0.1"; ReleaseName = "ESXi 8.0 Update 1a (EP1)"; ReleaseDate = "2023/06/01"; LatestStable = $false }
        "21495797" = @{ Version = "8.0.1"; ReleaseName = "ESXi 8.0 Update 1"; ReleaseDate = "2023/04/18"; LatestStable = $false }
        "21493926" = @{ Version = "8.0.0"; ReleaseName = "ESXi 8.0c (EP2)"; ReleaseDate = "2023/03/30"; LatestStable = $false }
        "21203435" = @{ Version = "8.0.0"; ReleaseName = "ESXi 8.0b (P01)"; ReleaseDate = "2023/02/14"; LatestStable = $false }
        "20842819" = @{ Version = "8.0.0"; ReleaseName = "ESXi 8.0a (EP1)"; ReleaseDate = "2022/12/08"; LatestStable = $false }
        "20513097" = @{ Version = "8.0.0"; ReleaseName = "ESXi 8.0 GA"; ReleaseDate = "2022/10/11"; LatestStable = $false }
    }
    
    # ESXi 7.0.x release mapping
    $esxi7Releases = @{
        "24585291" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3s"; ReleaseDate = "2025/03/04"; LatestStable = $true }
        "24411414" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3r (EP12)"; ReleaseDate = "2024/12/12"; LatestStable = $false }
        "23794027" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3q (P09)"; ReleaseDate = "2024/05/21"; LatestStable = $false }
        "23307199" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3p (EP11)"; ReleaseDate = "2024/04/11"; LatestStable = $false }
        "22348816" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3o (P08)"; ReleaseDate = "2023/09/28"; LatestStable = $false }
        "21930508" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3n (EP10)"; ReleaseDate = "2023/07/07"; LatestStable = $false }
        "21686933" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3m (EP9)"; ReleaseDate = "2023/05/03"; LatestStable = $false }
        "21424296" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3l (P07)"; ReleaseDate = "2023/03/30"; LatestStable = $false }
        "21313628" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3k (EP8)"; ReleaseDate = "2023/02/21"; LatestStable = $false }
        "21053776" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3j (EP7)"; ReleaseDate = "2023/01/31"; LatestStable = $false }
        "20842708" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3i (P06)"; ReleaseDate = "2022/12/08"; LatestStable = $false }
        "20328353" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3g (EP5)"; ReleaseDate = "2022/09/01"; LatestStable = $false }
        "20036589" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3f (P05)"; ReleaseDate = "2022/07/12"; LatestStable = $false }
        "19898904" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3e (EP4)"; ReleaseDate = "2022/06/14"; LatestStable = $false }
        "19482537" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3d (P04)"; ReleaseDate = "2022/03/29"; LatestStable = $false }
        "19290878" = @{ Version = "7.0.2"; ReleaseName = "ESXi 7.0 Update 2e (EP3)"; ReleaseDate = "2022/02/15"; LatestStable = $false }
        "19324898" = @{ Version = "7.0.1"; ReleaseName = "ESXi 7.0 Update 1e (EP4)"; ReleaseDate = "2022/02/15"; LatestStable = $false }
        "19193900" = @{ Version = "7.0.3"; ReleaseName = "ESXi 7.0 Update 3c"; ReleaseDate = "2022/01/27"; LatestStable = $false }
        "18538813" = @{ Version = "7.0.2"; ReleaseName = "ESXi 7.0 Update 2d (EP2)"; ReleaseDate = "2021/09/14"; LatestStable = $false }
        "18426014" = @{ Version = "7.0.2"; ReleaseName = "ESXi 7.0 Update 2c (P03)"; ReleaseDate = "2021/08/24"; LatestStable = $false }
        "17867351" = @{ Version = "7.0.2"; ReleaseName = "ESXi 7.0 Update 2a (EP1)"; ReleaseDate = "2021/04/29"; LatestStable = $false }
        "17630552" = @{ Version = "7.0.2"; ReleaseName = "ESXi 7.0 Update 2"; ReleaseDate = "2021/03/09"; LatestStable = $false }
        "17551050" = @{ Version = "7.0.1"; ReleaseName = "ESXi 7.0 Update 1d (EP3)"; ReleaseDate = "2021/02/02"; LatestStable = $false }
        "17325551" = @{ Version = "7.0.1"; ReleaseName = "ESXi 7.0 Update 1c (P02)"; ReleaseDate = "2020/12/17"; LatestStable = $false }
        "17168206" = @{ Version = "7.0.1"; ReleaseName = "ESXi 7.0 Update 1b (EP2)"; ReleaseDate = "2020/11/19"; LatestStable = $false }
        "17119627" = @{ Version = "7.0.1"; ReleaseName = "ESXi 7.0 Update 1a (EP1)"; ReleaseDate = "2020/11/04"; LatestStable = $false }
        "16850804" = @{ Version = "7.0.1"; ReleaseName = "ESXi 7.0 Update 1"; ReleaseDate = "2020/10/06"; LatestStable = $false }
        "16324942" = @{ Version = "7.0.0"; ReleaseName = "ESXi 7.0b (P01)"; ReleaseDate = "2020/06/23"; LatestStable = $false }
        "15843807" = @{ Version = "7.0.0"; ReleaseName = "ESXi 7.0 GA"; ReleaseDate = "2020/04/02"; LatestStable = $false }
    }
    
    # Check in ESXi 8.0 releases
    if ($esxi8Releases.ContainsKey($buildNumber)) {
        return $esxi8Releases[$buildNumber]
    }
    
    # Check in ESXi 7.0 releases
    if ($esxi7Releases.ContainsKey($buildNumber)) {
        return $esxi7Releases[$buildNumber]
    }
    
    # Unknown build number
    return @{
        Version = "Unknown";
        ReleaseName = "Unknown Release";
        ReleaseDate = "Unknown";
        LatestStable = $false
    }
}

function Test-CPUCompatibility {
    param (
        [string]$ProcessorType,
        [string]$Manufacturer,
        [string]$Model
    )
    
    # Define CPU families and specific models that are supported for ESXi 8.x
    $supportedCPUs = @{
        # Intel Xeon Scalable (Ice Lake and later)
        'Platinum' = @('8[0-9]{3}[A-Z]?')  # 8xxx series
        'Gold' = @('6[0-9]{3}[A-Z]?', '5[0-9]{3}[A-Z]?')  # 6xxx and 5xxx series
        'Silver' = @('4[0-9]{3}[A-Z]?')  # 4xxx series
        'Bronze' = @('3[0-9]{3}[A-Z]?')  # 3xxx series
        
        # Intel 2nd/3rd Gen Xeon Scalable CPUs (explicitly supported)
        'Cascadelake' = @(
            'Gold 6248', 'Gold 6246', 'Gold 6242', 'Gold 6240', 'Gold 6238',
            'Gold 6230', 'Gold 6226', 'Gold 6208U', 'Gold 5220', 'Gold 5218',
            'Gold 5217', 'Gold 5215', 'Silver 4215', 'Silver 4214', 'Silver 4210'
        )
        
        # 3rd Gen Xeon Scalable (Ice Lake)
        'IceLake' = @(
            'Gold 6338', 'Gold 6330', 'Gold 6326', 'Gold 5318', 'Gold 5315',
            'Silver 4316', 'Silver 4314', 'Silver 4310'
        )
        
        # Specific known-good models
        'Specific' = @(
            # Recent Xeon models (known compatible)
            'Gold 6150', 'Gold 6132', 'Gold 6126',
            'Silver 4114', 'Silver 4110'
        )
        
        # AMD EPYC 7xx2 (Rome) and 7xx3 (Milan) series
        'EPYC' = @(
            '7742', '7702', '7662', '7642', '7552',
            '7542', '7532', '7502', '7452', '7402',
            '7352', '7302', '7282', '7272', '7262',
            '7252', '7232',
            '7763', '7713', '7663', '7643', '7573',
            '7543', '7513', '7453', '7443', '7413',
            '7343', '7313'
        )
        
        # Explicitly unsupported models
        'Unsupported' = @(
            'E5-2680 v3', 'E5-2660 v3', 'E5-2650 v3', 'E5-2640 v3', 'E5-2630 v3',
            'E5-2620 v3', 'E5-2609 v3', 'E5-2603 v3', 'E5-2697 v2', 'E5-2695 v2',
            'E5-2690 v2', 'E5-2680 v2', 'E5-2670 v2', 'E5-2660 v2', 'E5-2650 v2',
            'E5-2640 v2', 'E5-2630 v2', 'E5-2620 v2', 'E5-2609 v2', 'E5-2603 v2',
            'E5-2697 v1', 'E5-2695 v1', 'E5-2690 v1', 'E5-2680 v1', 'E5-2670 v1'
        )
    }
    
    # Create a result object with detailed information
    $result = [PSCustomObject]@{
        IsCompatible = $false
        Reason = ""
        CPUModel = $ProcessorType
        CompatibilityNotes = ""
        Icon = "X" # Using ASCII characters instead of Unicode
    }
    
    # First check explicitly unsupported models
    foreach ($unsupportedCPU in $supportedCPUs['Unsupported']) {
        if ($ProcessorType -match [regex]::Escape($unsupportedCPU)) {
            $result.Reason = "CPU model $ProcessorType is explicitly unsupported for ESXi 8.x"
            $result.CompatibilityNotes = "This CPU generation is too old for ESXi 8.x"
            $result.Icon = "X"
            Write-Log -Message $result.Reason -Level 'WARNING'
            return $result
        }
    }
    
    # Check specific supported models
    foreach ($cpuCategory in @('Specific', 'Cascadelake', 'IceLake')) {
        foreach ($specificCPU in $supportedCPUs[$cpuCategory]) {
            if ($ProcessorType -match [regex]::Escape($specificCPU)) {
                $result.IsCompatible = $true
                $result.Reason = "CPU model $ProcessorType is explicitly supported for ESXi 8.x"
                $result.CompatibilityNotes = "This CPU model is explicitly verified as compatible"
                $result.Icon = "√"
                Write-Log -Message $result.Reason -Level 'SUCCESS'
                return $result
            }
        }
    }
    
    # Check Intel Scalable family processors (Cascade Lake and newer)
    foreach ($family in @('Platinum', 'Gold', 'Silver', 'Bronze')) {
        foreach ($pattern in $supportedCPUs[$family]) {
            if ($ProcessorType -match "Intel.*Xeon.*$family.*$pattern") {
                $result.IsCompatible = $true
                $result.Reason = "CPU model $ProcessorType is supported for ESXi 8.x (Scalable family)"
                $result.CompatibilityNotes = "This Intel Xeon Scalable CPU is compatible"
                $result.Icon = "√"
                Write-Log -Message $result.Reason -Level 'SUCCESS'
                return $result
            }
        }
    }
    
    # Check AMD EPYC processors
    if ($ProcessorType -match "AMD.*EPYC") {
        foreach ($model in $supportedCPUs['EPYC']) {
            if ($ProcessorType -match $model) {
                $result.IsCompatible = $true
                $result.Reason = "CPU model $ProcessorType is supported for ESXi 8.x (AMD EPYC)"
                $result.CompatibilityNotes = "This AMD EPYC CPU is compatible"
                $result.Icon = "√"
                Write-Log -Message $result.Reason -Level 'SUCCESS'
                return $result
            }
        }
    }
    
    # If we're still here, check generation for Intel CPUs
    if ($ProcessorType -match "Intel.*Xeon.*E5") {
        # Check for v4 or higher which are generally compatible
        if ($ProcessorType -match "v[4-9]") {
            $result.IsCompatible = $true
            $result.Reason = "CPU model $ProcessorType is likely supported for ESXi 8.x (Broadwell or newer)"
            $result.CompatibilityNotes = "E5 v4 or newer CPUs are generally compatible"
            $result.Icon = "√"
            Write-Log -Message $result.Reason -Level 'SUCCESS'
            return $result
        }
    }
    
    # If no match found, consider potentially compatible but warn
    $result.IsCompatible = $false
    $result.Reason = "CPU model $ProcessorType is not verified as supported for ESXi 8.x"
    $result.CompatibilityNotes = "Could not verify compatibility - manual check recommended"
    $result.Icon = "?"
    Write-Log -Message $result.Reason -Level 'WARNING'
    return $result
}


function Test-StorageReadiness {
    param (
        [array]$VolumeInfo,
        [double]$MinimumRequiredSpaceGB,
        [double]$MinimumBootbankFreePercentage
    )
    
    $osdataPartition = $VolumeInfo | Where-Object { $_.VolumeName -like "OSDATA*" }
    $bootbank1Partition = $VolumeInfo | Where-Object { $_.VolumeName -eq "BOOTBANK1" }
    $bootbank2Partition = $VolumeInfo | Where-Object { $_.VolumeName -eq "BOOTBANK2" }
    
    # Initialize result object with detailed information
    $result = [PSCustomObject]@{
        IsReady = $true
        Issues = @()
        OSDATASize = if ($osdataPartition) { $osdataPartition.TotalSizeGB } else { 0 }
        OSDATAFree = if ($osdataPartition) { $osdataPartition.FreeSpaceGB } else { 0 }
        BOOTBANK1Size = if ($bootbank1Partition) { $bootbank1Partition.TotalSizeGB } else { 0 }
        BOOTBANK1Free = if ($bootbank1Partition) { $bootbank1Partition.FreeSpaceGB } else { 0 }
        BOOTBANK2Size = if ($bootbank2Partition) { $bootbank2Partition.TotalSizeGB } else { 0 }
        BOOTBANK2Free = if ($bootbank2Partition) { $bootbank2Partition.FreeSpaceGB } else { 0 }
    }
    
    # Check OSDATA partition
    if ($osdataPartition) {
        if ($osdataPartition.FreeSpaceGB -lt $MinimumRequiredSpaceGB) {
            $result.IsReady = $false
            $issue = "OSDATA has insufficient free space: $($osdataPartition.FreeSpaceGB) GB (Required: $MinimumRequiredSpaceGB GB)"
            $result.Issues += $issue
            Write-Log -Message $issue -Level 'WARNING'
        }
    }
    else {
        # For older ESXi versions that might not have OSDATA
        $result.Issues += "No OSDATA partition found - this may indicate an older ESXi version"
        Write-Log -Message "No OSDATA partition found - this may indicate an older ESXi version" -Level 'WARNING'
    }
    
    # Function to check bootbank partitions
    function Test-BootbankPartition {
        param (
            $Partition, 
            [string]$PartitionName,
            [double]$RequiredFreePercentage
        )
        
        if (-not $Partition) {
            $result.IsReady = $false
            $issue = "$PartitionName partition not found"
            $result.Issues += $issue
            Write-Log -Message $issue -Level 'WARNING'
            return
        }
        
        if ($Partition.TotalSizeGB -lt 4) {
            $result.IsReady = $false
            $issue = "$PartitionName is undersized (< 4 GB): $($Partition.TotalSizeGB) GB"
            $result.Issues += $issue
            Write-Log -Message $issue -Level 'WARNING'
        }
        
        $freePercentage = ($Partition.FreeSpaceGB / $Partition.TotalSizeGB) * 100
        if ($freePercentage -lt $RequiredFreePercentage) {
            $result.IsReady = $false
            $issue = "$PartitionName has insufficient free space: $($Partition.FreeSpaceGB) GB ($($freePercentage.ToString('F2'))% free, required: $RequiredFreePercentage%)"
            $result.Issues += $issue
            Write-Log -Message $issue -Level 'WARNING'
        }
    }
    
    # Check bootbank partitions
    Test-BootbankPartition -Partition $bootbank1Partition -PartitionName "BOOTBANK1" -RequiredFreePercentage $MinimumBootbankFreePercentage
    Test-BootbankPartition -Partition $bootbank2Partition -PartitionName "BOOTBANK2" -RequiredFreePercentage $MinimumBootbankFreePercentage
    
    # Additional storage sanity checks (to prevent false negatives)
    $allVolumes = $VolumeInfo | Where-Object { $_.VolumeName -notlike "OSDATA*" -and $_.VolumeName -ne "BOOTBANK1" -and $_.VolumeName -ne "BOOTBANK2" }
    $totalFreeSpace = ($allVolumes | Measure-Object -Property FreeSpaceGB -Sum).Sum
    
    # If we have significant free space elsewhere but issues with specific partitions,
    # add a note about possible partition resizing
    if ($result.IsReady -eq $false -and $totalFreeSpace -gt $MinimumRequiredSpaceGB * 2) {
        $result.Issues += "NOTE: System has $totalFreeSpace GB free space on other partitions - partition resizing might resolve space issues"
    }
    
    if ($result.IsReady) {
        Write-Log -Message "Storage check passed - sufficient space available for upgrade" -Level 'SUCCESS'
    }
    else {
        Write-Log -Message "Storage check failed - issues found: $($result.Issues -join '; ')" -Level 'WARNING'
    }
    
    return $result
}

function Test-DirectUpgradePathAvailable {
    param (
        [string]$CurrentVersion,
        [string]$TargetVersion
    )
    
    $result = [PSCustomObject]@{
        IsDirectUpgradePossible = $false
        RequiredIntermediateVersion = $null
        Reason = ""
    }
    
    # Convert versions to Version objects for comparison
    $currentVer = [version]($CurrentVersion -replace '^([0-9]+\.[0-9]+).*', '$1')
    $targetVer = [version]($TargetVersion -replace '^([0-9]+\.[0-9]+).*', '$1')
    
    # Check for direct upgrade path
    # ESXi 6.7 or 7.0 can upgrade directly to 8.0
    if ($currentVer -ge [version]"6.7") {
        $result.IsDirectUpgradePossible = $true
        $result.Reason = "Direct upgrade path available from ESXi $CurrentVersion to $TargetVersion"
        Write-Log -Message $result.Reason -Level 'SUCCESS'
    }
    elseif ($currentVer -ge [version]"6.5") {
        $result.IsDirectUpgradePossible = $false
        $result.RequiredIntermediateVersion = "6.7"
        $result.Reason = "Must upgrade to ESXi 6.7 first, then to $TargetVersion"
        Write-Log -Message $result.Reason -Level 'WARNING'
    }
    elseif ($currentVer -ge [version]"6.0") {
        $result.IsDirectUpgradePossible = $false
        $result.RequiredIntermediateVersion = "6.5 or 6.7"
        $result.Reason = "Must upgrade to ESXi 6.5 or 6.7 first, then to $TargetVersion"
        Write-Log -Message $result.Reason -Level 'WARNING'
    }
    elseif ($currentVer -ge [version]"5.5") {
        $result.IsDirectUpgradePossible = $false
        $result.RequiredIntermediateVersion = "6.0, then 6.5 or 6.7"
        $result.Reason = "Multi-step upgrade required: 5.5 → 6.0 → 6.5/6.7 → $TargetVersion"
        Write-Log -Message $result.Reason -Level 'WARNING'
    }
    else {
        $result.IsDirectUpgradePossible = $false
        $result.RequiredIntermediateVersion = "Multiple intermediate versions"
        $result.Reason = "ESXi version $CurrentVersion is too old for upgrade path to $TargetVersion"
        Write-Log -Message $result.Reason -Level 'ERROR'
    }
    
    return $result
}

function Get-UpgradeReadinessCategory {
    param (
        [bool]$CPUCompatible,
        [bool]$StorageReady,
        [bool]$DirectUpgradePossible,
        [bool]$AlreadyUpToDate = $false
    )
    
    # Check for already up-to-date systems first
    if ($AlreadyUpToDate) {
        return "Already Up-To-Date"
    }
    
    # Determine the most specific category based on issues
    if ($CPUCompatible -and $StorageReady -and $DirectUpgradePossible) {
        return "Ready"
    }
    elseif (-not $CPUCompatible -and $StorageReady -and $DirectUpgradePossible) {
        return "CPU Incompatible"
    }
    elseif ($CPUCompatible -and -not $StorageReady -and $DirectUpgradePossible) {
        return "Storage Issues"
    }
    elseif ($CPUCompatible -and $StorageReady -and -not $DirectUpgradePossible) {
        return "Requires Intermediate Upgrade"
    }
    else {
        return "Multiple Issues"
    }
}

function Get-UpgradePathInfo {
    param (
        [Parameter(Mandatory = $true)]
        [string]$CurrentVersion,
        
        [Parameter(Mandatory = $true)]
        [string]$CurrentBuild,
        
        [Parameter(Mandatory = $true)]
        [string]$TargetVersion,
        
        [Parameter(Mandatory = $false)]
        [string]$TargetBuild = "24674464"
    )
    
    # Get current version info from build number
    $currentReleaseInfo = Get-ESXiReleaseInfo -BuildNumber $CurrentBuild
    
    # For simplicity, we're focusing on 7.0.x -> 8.0.x upgrade paths
    $majorCurrentVersion = $CurrentVersion.Split('.')[0]
    $majorTargetVersion = $TargetVersion.Split('.')[0]
    
    # Define our result object
    $result = [PSCustomObject]@{
        DirectUpgradePossible = $false
        UpgradePathNotes = ""
        RecommendedPath = ""
        AlreadyUpToDate = $false
        CurrentVersionDetail = $currentReleaseInfo.ReleaseName
        LatestVersionInSeries = ""
    }
    
    # Get latest stable versions
    $latest7 = "7.0.3 Update 3s (Build 24585291)"
    $latest8 = "8.0.3 Update 3e (Build 24674464)"
    
    # Set the latest version in series based on major version
    $result.LatestVersionInSeries = if ($majorCurrentVersion -eq "7") { $latest7 } else { $latest8 }
    
    # Check if already on target version by build number (EXACT match)
    if ($CurrentBuild -eq $TargetBuild) {
        # Exact build match - already on the latest version
        $result.AlreadyUpToDate = $true
        $result.DirectUpgradePossible = $true
        $result.UpgradePathNotes = "Already on latest ESXi $($currentReleaseInfo.ReleaseName) (Build $CurrentBuild)"
        $result.RecommendedPath = "No upgrade needed - already on latest version"
        return $result
    }
    # Check for same 8.0.3 version but different build
    elseif ($majorCurrentVersion -eq "8" -and $currentReleaseInfo.Version -eq "8.0.3" -and $CurrentBuild -ne $TargetBuild) {
        $result.AlreadyUpToDate = $false
        $result.DirectUpgradePossible = $true
        $result.UpgradePathNotes = "Running ESXi 8.0.3 $($currentReleaseInfo.ReleaseName) (Build $CurrentBuild) - can update to latest 8.0.3 Update 3e (Build $TargetBuild)"
        $result.RecommendedPath = "Update to ESXi 8.0.3 Update 3e (Build $TargetBuild)"
        return $result
    }
    # Check for the latest 7.0.3 version (special case)
    elseif ($CurrentBuild -eq "24585291" -and $majorCurrentVersion -eq "7") {
        # Already on latest 7.0.3 Update 3s
        $result.AlreadyUpToDate = $false # Not on target if target is 8.0.3
        $result.DirectUpgradePossible = $true
        $result.UpgradePathNotes = "Running the latest ESXi 7.0.3 Update 3s (Build 24585291)"
        $result.RecommendedPath = "Upgrade to ESXi 8.0.3 Update 3e (Build $TargetBuild) if hardware is compatible"
        return $result
    }
    
    # Direct upgrades from 7.0.x to 8.0.x are possible
    if ($majorCurrentVersion -eq "7" -and $majorTargetVersion -eq "8") {
        # Check if the current version can be directly upgraded
        if ($CurrentVersion -match "^7\.0\.[3-9]") {
            # If already on latest 7.0.x
            if ($CurrentBuild -eq "24585291") {
                $result.DirectUpgradePossible = $true
                $result.UpgradePathNotes = "Direct upgrade from $($currentReleaseInfo.ReleaseName) to ESXi 8.0.3 Update 3e (Build $TargetBuild) is possible"
                $result.RecommendedPath = "Upgrade directly to ESXi 8.0.3 Update 3e (Build $TargetBuild)"
            }
            else {
                $result.DirectUpgradePossible = $true
                $result.UpgradePathNotes = "Running ESXi $($currentReleaseInfo.ReleaseName) - direct upgrade to 8.0.3 is possible"
                $result.RecommendedPath = "Option 1: Upgrade to ESXi 7.0.3 Update 3s (Build 24585291) first, then to ESXi 8.0.3 Update 3e (Build $TargetBuild) | Option 2: Upgrade directly to ESXi 8.0.3 Update 3e (Build $TargetBuild)"
            }
        }
        else {
            $result.DirectUpgradePossible = $false
            $result.UpgradePathNotes = "Must upgrade to ESXi 7.0.3 before upgrading to 8.0.x"
            $result.RecommendedPath = "Upgrade to ESXi 7.0.3 Update 3s (Build 24585291) first, then to ESXi 8.0.3 Update 3e (Build $TargetBuild)"
        }
    }
    # Already on target major version (e.g., 8.0.x to 8.0.x)
    elseif ($majorCurrentVersion -eq $majorTargetVersion) {
        if ($majorCurrentVersion -eq "8") {
            $result.DirectUpgradePossible = $true
            $result.UpgradePathNotes = "Running ESXi $($currentReleaseInfo.ReleaseName) - direct upgrade to 8.0.3 Update 3e is possible"
            $result.RecommendedPath = "Upgrade to ESXi 8.0.3 Update 3e (Build $TargetBuild)"
        }
        else {
            $result.DirectUpgradePossible = $true
            $result.UpgradePathNotes = "Running ESXi $($currentReleaseInfo.ReleaseName) - direct upgrade to latest 7.0.3 is possible"
            $result.RecommendedPath = "Upgrade to ESXi 7.0.3 Update 3s (Build 24585291), then consider 8.0.3 if hardware compatible"
        }
    }
    else {
        # Default case - unknown upgrade path
        $result.DirectUpgradePossible = $false
        $result.UpgradePathNotes = "Unknown upgrade path from ESXi $CurrentVersion (Build $CurrentBuild) to $TargetVersion"
        $result.RecommendedPath = "Please consult VMware upgrade documentation"
    }
    
    return $result
}

function Analyze-ESXiHost {
    param (
        [string]$HostName,
        [string]$IPAddress = "",
        [PSCredential]$Credential,
        [string]$TargetVersion,
        [string]$TargetESXiBuild = "24674464",
        [string]$TargetESXiDetail = "ESXi 8.0.3 Update 3e (Build 24674464)",
        [double]$MinimumRequiredSpaceGB,
        [double]$MinimumBootbankFreePercentage
    )
    
    # Initialize result object
    $hostResult = [PSCustomObject]@{
        HostName = $HostName
        IPAddress = $IPAddress
        Version = ""
        Build = ""
        VersionDetail = ""
        TargetVersion = $TargetVersion
        TargetVersionDetail = $TargetESXiDetail
        Manufacturer = ""
        Model = ""
        ProcessorType = ""
        MemoryGB = 0
        ImageProfile = ""
        InstallDate = ""
        CPUCompatible = $false
        CPUCompatibilityNotes = ""
        CPUCompatibilityIcon = "❓" # Default unknown icon
        StorageReady = $false
        StorageIssues = @()
        OSDATAFreeGB = 0
        OSDATASizeGB = 0
        DirectUpgradePossible = $false
        AlreadyUpToDate = $false
        UpgradePathNotes = ""
        RecommendedPath = ""
        UpgradeReadiness = "Not Ready"
        UpgradeReadinessCategory = ""
        DetailedInfo = $null
    }
    
    try {
        Write-Log -Message "Starting analysis of host: $HostName" -Level 'INFO'
        
        # Connect to ESXi host
        $server = Connect-ESXiHost -HostName $HostName -Credential $Credential -IPAddress $IPAddress
        if ($null -eq $server) {
            throw "Failed to establish connection"
        }
        
        # Get basic host info
        $vmhost = Get-ESXiHostInfo -HostName $HostName -Server $server
        $hostResult.Version = $vmhost.Version
        $hostResult.Build = $vmhost.Build
        
        # Get version detail from build mapping
        $releaseInfo = Get-ESXiReleaseInfo -BuildNumber $vmhost.Build
        $hostResult.VersionDetail = $releaseInfo.ReleaseName
        
        # Get additional info
        $hardwareInfo = Get-ESXiHardwareInfo -VMHost $vmhost
        $hostResult.Manufacturer = $hardwareInfo.Manufacturer
        $hostResult.Model = $hardwareInfo.Model
        $hostResult.ProcessorType = $hardwareInfo.ProcessorType
        $hostResult.MemoryGB = $hardwareInfo.MemoryGB
        
        $hostResult.ImageProfile = Get-ESXiImageProfile -VMHost $vmhost
        $hostResult.InstallDate = Get-ESXiInstallDate -VMHost $vmhost
        
        # Get filesystem info
        $volumeInfo = Get-ESXiFilesystemInfo -VMHost $vmhost
        
        # Test CPU compatibility
        $cpuResult = Test-CPUCompatibility -ProcessorType $hardwareInfo.ProcessorType -Manufacturer $hardwareInfo.Manufacturer -Model $hardwareInfo.Model
        $hostResult.CPUCompatible = $cpuResult.IsCompatible
        $hostResult.CPUCompatibilityNotes = $cpuResult.CompatibilityNotes
        $hostResult.CPUCompatibilityIcon = $cpuResult.Icon
        
        # Test storage readiness
        $storageResult = Test-StorageReadiness -VolumeInfo $volumeInfo -MinimumRequiredSpaceGB $MinimumRequiredSpaceGB -MinimumBootbankFreePercentage $MinimumBootbankFreePercentage
        $hostResult.StorageReady = $storageResult.IsReady
        $hostResult.StorageIssues = $storageResult.Issues
        $hostResult.OSDATAFreeGB = $storageResult.OSDATAFree
        $hostResult.OSDATASizeGB = $storageResult.OSDATASize
        
        # Test upgrade path - updated to check for already on target version
        $upgradePathResult = Get-UpgradePathInfo -CurrentVersion $vmhost.Version -CurrentBuild $vmhost.Build -TargetVersion $TargetVersion -TargetBuild $TargetESXiBuild
        $hostResult.DirectUpgradePossible = $upgradePathResult.DirectUpgradePossible
        $hostResult.UpgradePathNotes = $upgradePathResult.UpgradePathNotes
        $hostResult.RecommendedPath = $upgradePathResult.RecommendedPath
        $hostResult.AlreadyUpToDate = $upgradePathResult.AlreadyUpToDate
        
        # Determine overall readiness - now with proper handling for already-on-target hosts
        if ($upgradePathResult.AlreadyUpToDate) {
            $hostResult.UpgradeReadiness = "Already Up-To-Date"
            $hostResult.UpgradeReadinessCategory = "Already Up-To-Date"
        } 
        elseif ($cpuResult.IsCompatible -and $storageResult.IsReady -and $upgradePathResult.DirectUpgradePossible) {
            $hostResult.UpgradeReadiness = "Ready for Upgrade"
            $hostResult.UpgradeReadinessCategory = "Ready"
        } 
        else {
            $hostResult.UpgradeReadiness = "Not Ready"
            $hostResult.UpgradeReadinessCategory = Get-UpgradeReadinessCategory -CPUCompatible $cpuResult.IsCompatible -StorageReady $storageResult.IsReady -DirectUpgradePossible $upgradePathResult.DirectUpgradePossible
        }
        
        # Store detailed info
        $hostResult.DetailedInfo = [PSCustomObject]@{
            Hardware = $hardwareInfo
            Network = Get-ESXiNetworkInfo -VMHost $vmhost
            Storage = $volumeInfo
            SystemTime = Get-ESXiSystemTime -VMHost $vmhost
            CPUResult = $cpuResult
            StorageResult = $storageResult
            UpgradePathResult = $upgradePathResult
        }
        
        Write-Log -Message "Completed analysis of host $HostName - Result: $($hostResult.UpgradeReadiness)" -Level 'INFO'
        
        # Disconnect from the server
        try {
            Disconnect-VIServer -Server $server -Confirm:$false -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Log -Message "Disconnected from host $HostName" -Level 'INFO'
        }
        catch {
            Write-Log -Message "Error disconnecting from host $HostName- $_" -Level 'WARNING'
        }
        
        return $hostResult
    }
    catch {
        Write-Log -Message "Failed to analyze host $HostName - $_" -Level 'ERROR'
        Write-FailureLog -HostName $HostName -IPAddress $IPAddress -Reason $_.ToString()
        
        # Update host result with failure
        $hostResult.UpgradeReadiness = "Failed to Check"
        $hostResult.UpgradeReadinessCategory = "Failed to Check"
        
        # Try to disconnect in case connection was established
        if ($server) {
            try {
                Disconnect-VIServer -Server $server -Confirm:$false -Force -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
                # Ignore disconnect errors during failure handling
            }
        }
        
        return $hostResult
    }
}

#endregion

#region Server List Processing

function Get-TargetServers {
    param (
        [string[]]$Servers,
        [string]$ServerListFile,
        [string]$NameMatch
    )
    
    $targetList = @()
    
    # Process servers passed directly via parameters
    if ($Servers) {
        Write-Log -Message "Processing direct server inputs" -Level 'INFO'
        foreach ($server in $Servers) {
            $targetList += [PSCustomObject]@{
                HostName = $server
                IPAddress = ""
            }
            Write-Log -Message "Added server: $server" -Level 'INFO'
        }
    }
    
	# Process servers from CSV file
	if ($ServerListFile) {
		if (Test-Path -Path $ServerListFile) {
			Write-Log -Message "Processing server list from file: $ServerListFile" -Level 'INFO'

			try {
				# Read raw CSV content
				$csvContent = Get-Content -Path $ServerListFile -ErrorAction Stop

				if ($csvContent.Count -lt 1) {
					Write-Log -Message "CSV file is empty or unreadable" -Level 'WARNING'
					return @()
				}

				# Define acceptable aliases for required fields
				$hostAliases = @('Host Name', 'hostname', 'host')
				$ipAliases = @('IP', 'IP Address', 'IPAddress')

				# Locate the header row dynamically
				$headerLineIndex = $null
				for ($i = 0; $i -lt $csvContent.Count; $i++) {
					$line = $csvContent[$i]
					if ($hostAliases | Where-Object { $line -match $_ }) {
						$headerLineIndex = $i
						break
					}
				}

				if ($null -eq $headerLineIndex) {
					Write-Log -Message "No valid header line with hostname or IP columns found." -Level 'ERROR'
					return @()
				}

				$tempFile = [System.IO.Path]::GetTempFileName()
				try {
					# Write the header and remaining content to temp
					$csvContent[$headerLineIndex..($csvContent.Count - 1)] | Where-Object { $_ -match '\S' } | Set-Content -Path $tempFile

					# Import CSV
					$csvData = Import-Csv -Path $tempFile
					$processedCount = 0
					$foundCount = 0

					Write-Log -Message "Detected header row at line $($headerLineIndex + 1). Processing CSV data..." -Level 'INFO'

					foreach ($row in $csvData) {
						$processedCount++

						$hostName = $null
						foreach ($alias in $hostAliases) {
							if ($row.PSObject.Properties.Name -contains $alias -and ![string]::IsNullOrWhiteSpace($row.$alias)) {
								$hostName = $row.$alias.Trim()
								break
							}
						}

						if ($hostName -and (!$NameMatch -or $hostName -match $NameMatch)) {
							$foundCount++

							$ipAddress = $null
							foreach ($ipAlias in $ipAliases) {
								if ($row.PSObject.Properties.Name -contains $ipAlias -and ![string]::IsNullOrWhiteSpace($row.$ipAlias)) {
									$ipAddress = $row.$ipAlias.Trim()
									break
								}
							}

							$targetList += [PSCustomObject]@{
								HostName  = $hostName
								IPAddress = $ipAddress
							}

							Write-Log -Message "Added server from CSV: $hostName $(if ($ipAddress) {"(IP: $ipAddress)"})" -Level 'INFO'
						}
					}

					Write-Log -Message "Total rows processed: $processedCount" -Level 'INFO'
					Write-Log -Message "ESXi hosts found: $foundCount" -Level 'INFO'
				}
				finally {
					if (Test-Path $tempFile) {
						Remove-Item -Path $tempFile -Force
					}
				}
			}
			catch {
				Write-Log -Message "Error processing CSV file: $_" -Level 'ERROR'
			}
		}
		else {
			Write-Log -Message "Server list file not found: $ServerListFile" -Level 'ERROR'
		}
	}
    
    # Ensure we have a valid array
    if ($null -eq $targetList) {
        $targetList = @()
    }
    
    Write-Log -Message "Found $($targetList.Count) unique servers to process" -Level 'INFO'
    return $targetList
}

#endregion

#region Reporting Functions

function Export-ResultsToCSV {
    param (
        [array]$Results,
        [string]$CsvPath
    )
    
    try {
        # Create a simplified object for CSV export with improved column order
        # but without the CPUCompatibilityIcon property
        $csvData = $Results | ForEach-Object {
            [PSCustomObject]@{
                # Primary columns for quick assessment
                UpgradeReadiness = $_.UpgradeReadiness
                HostName = $_.HostName
                IPAddress = $_.IPAddress
                
                # Version information (current and target)
                Version = $_.Version
                Build = $_.Build
                VersionDetail = $_.VersionDetail
                TargetVersion = $_.TargetVersion
                TargetVersionDetail = $_.TargetVersionDetail
                
                # Upgrade path information
                DirectUpgradePossible = $_.DirectUpgradePossible
                UpgradePathNotes = $_.UpgradePathNotes
                RecommendedPath = $_.RecommendedPath
                AlreadyUpToDate = $_.AlreadyUpToDate
                
                # Compatibility information
                CPUCompatible = $_.CPUCompatible
                CPUCompatibilityNotes = $_.CPUCompatibilityNotes
                # CPUCompatibilityIcon removed from CSV export
                StorageReady = $_.StorageReady
                StorageIssues = ($_.StorageIssues -join "; ")
                
                # Hardware information
                Manufacturer = $_.Manufacturer
                Model = $_.Model
                ProcessorType = $_.ProcessorType
                MemoryGB = $_.MemoryGB
                OSDATASizeGB = $_.OSDATASizeGB
                OSDATAFreeGB = $_.OSDATAFreeGB
                
                # Additional information
                ImageProfile = $_.ImageProfile
                InstallDate = $_.InstallDate
                UpgradeReadinessCategory = $_.UpgradeReadinessCategory
            }
        }
        
        # Sort results by upgrade readiness (Ready first, then Already Up-To-Date, then others)
        $sortedResults = $csvData | Sort-Object -Property @{
            Expression = {
                switch ($_.UpgradeReadiness) {
                    "Ready for Upgrade" { 1 }
                    "Already Up-To-Date" { 2 }
                    "Not Ready" { 3 }
                    "Failed to Check" { 4 }
                    default { 5 }
                }
            }
        }, HostName
        
        # Export to CSV
        $sortedResults | Export-Csv -Path $CsvPath -NoTypeInformation
        
        Write-Log -Message "Results exported to CSV: $CsvPath" -Level 'SUCCESS'
        return $true
    }
    catch {
        Write-Log -Message "Failed to export results to CSV: $_" -Level 'ERROR'
        return $false
    }
}

function Test-CPUCompatibility {
    param (
        [string]$ProcessorType,
        [string]$Manufacturer,
        [string]$Model
    )
    
    # Define CPU families and specific models that are supported for ESXi 8.x
    $supportedCPUs = @{
        # Intel Xeon Scalable (Ice Lake and later)
        'Platinum' = @('8[0-9]{3}[A-Z]?')  # 8xxx series
        'Gold' = @('6[0-9]{3}[A-Z]?', '5[0-9]{3}[A-Z]?')  # 6xxx and 5xxx series
        'Silver' = @('4[0-9]{3}[A-Z]?')  # 4xxx series
        'Bronze' = @('3[0-9]{3}[A-Z]?')  # 3xxx series
        
        # Intel 2nd/3rd Gen Xeon Scalable CPUs (explicitly supported)
        'Cascadelake' = @(
            'Gold 6248', 'Gold 6246', 'Gold 6242', 'Gold 6240', 'Gold 6238',
            'Gold 6230', 'Gold 6226', 'Gold 6208U', 'Gold 5220', 'Gold 5218',
            'Gold 5217', 'Gold 5215', 'Silver 4215', 'Silver 4214', 'Silver 4210'
        )
        
        # 3rd Gen Xeon Scalable (Ice Lake)
        'IceLake' = @(
            'Gold 6338', 'Gold 6330', 'Gold 6326', 'Gold 5318', 'Gold 5315',
            'Silver 4316', 'Silver 4314', 'Silver 4310'
        )
        
        # Specific known-good models
        'Specific' = @(
            # Recent Xeon models (known compatible)
            'Gold 6150', 'Gold 6132', 'Gold 6126',
            'Silver 4114', 'Silver 4110'
        )
        
        # AMD EPYC 7xx2 (Rome) and 7xx3 (Milan) series
        'EPYC' = @(
            '7742', '7702', '7662', '7642', '7552',
            '7542', '7532', '7502', '7452', '7402',
            '7352', '7302', '7282', '7272', '7262',
            '7252', '7232',
            '7763', '7713', '7663', '7643', '7573',
            '7543', '7513', '7453', '7443', '7413',
            '7343', '7313'
        )
        
        # Explicitly unsupported models
        'Unsupported' = @(
            'E5-2680 v3', 'E5-2660 v3', 'E5-2650 v3', 'E5-2640 v3', 'E5-2630 v3',
            'E5-2620 v3', 'E5-2609 v3', 'E5-2603 v3', 'E5-2697 v2', 'E5-2695 v2',
            'E5-2690 v2', 'E5-2680 v2', 'E5-2670 v2', 'E5-2660 v2', 'E5-2650 v2',
            'E5-2640 v2', 'E5-2630 v2', 'E5-2620 v2', 'E5-2609 v2', 'E5-2603 v2',
            'E5-2697 v1', 'E5-2695 v1', 'E5-2690 v1', 'E5-2680 v1', 'E5-2670 v1'
        )
    }
    
    # Create a result object with detailed information
    $result = [PSCustomObject]@{
        IsCompatible = $false
        Reason = ""
        CPUModel = $ProcessorType
        CompatibilityNotes = ""
        Icon = "X" # Using ASCII characters instead of Unicode
    }
    
    # First check explicitly unsupported models
    foreach ($unsupportedCPU in $supportedCPUs['Unsupported']) {
        if ($ProcessorType -match [regex]::Escape($unsupportedCPU)) {
            $result.Reason = "CPU model $ProcessorType is explicitly unsupported for ESXi 8.x"
            $result.CompatibilityNotes = "This CPU generation is too old for ESXi 8.x"
            $result.Icon = "X"
            Write-Log -Message $result.Reason -Level 'WARNING'
            return $result
        }
    }
    
    # Check specific supported models
    foreach ($cpuCategory in @('Specific', 'Cascadelake', 'IceLake')) {
        foreach ($specificCPU in $supportedCPUs[$cpuCategory]) {
            if ($ProcessorType -match [regex]::Escape($specificCPU)) {
                $result.IsCompatible = $true
                $result.Reason = "CPU model $ProcessorType is explicitly supported for ESXi 8.x"
                $result.CompatibilityNotes = "This CPU model is explicitly verified as compatible"
                $result.Icon = "√"
                Write-Log -Message $result.Reason -Level 'SUCCESS'
                return $result
            }
        }
    }
    
    # Check Intel Scalable family processors (Cascade Lake and newer)
    foreach ($family in @('Platinum', 'Gold', 'Silver', 'Bronze')) {
        foreach ($pattern in $supportedCPUs[$family]) {
            if ($ProcessorType -match "Intel.*Xeon.*$family.*$pattern") {
                $result.IsCompatible = $true
                $result.Reason = "CPU model $ProcessorType is supported for ESXi 8.x (Scalable family)"
                $result.CompatibilityNotes = "This Intel Xeon Scalable CPU is compatible"
                $result.Icon = "√"
                Write-Log -Message $result.Reason -Level 'SUCCESS'
                return $result
            }
        }
    }
    
    # Check AMD EPYC processors
    if ($ProcessorType -match "AMD.*EPYC") {
        foreach ($model in $supportedCPUs['EPYC']) {
            if ($ProcessorType -match $model) {
                $result.IsCompatible = $true
                $result.Reason = "CPU model $ProcessorType is supported for ESXi 8.x (AMD EPYC)"
                $result.CompatibilityNotes = "This AMD EPYC CPU is compatible"
                $result.Icon = "√"
                Write-Log -Message $result.Reason -Level 'SUCCESS'
                return $result
            }
        }
    }
    
    # If we're still here, check generation for Intel CPUs
    if ($ProcessorType -match "Intel.*Xeon.*E5") {
        # Check for v4 or higher which are generally compatible
        if ($ProcessorType -match "v[4-9]") {
            $result.IsCompatible = $true
            $result.Reason = "CPU model $ProcessorType is likely supported for ESXi 8.x (Broadwell or newer)"
            $result.CompatibilityNotes = "E5 v4 or newer CPUs are generally compatible"
            $result.Icon = "√"
            Write-Log -Message $result.Reason -Level 'SUCCESS'
            return $result
        }
    }
    
    # If no match found, consider potentially compatible but warn
    $result.IsCompatible = $false
    $result.Reason = "CPU model $ProcessorType is not verified as supported for ESXi 8.x"
    $result.CompatibilityNotes = "Could not verify compatibility - manual check recommended"
    $result.Icon = "?"
    Write-Log -Message $result.Reason -Level 'WARNING'
    return $result
}

function Generate-HTMLReport {
    param (
        [array]$Results,
        [string]$ReportPath,
        [string]$TargetESXiVersion
    )
    
    try {
        # Ensure Results is an array
        if ($null -eq $Results) {
            $Results = @()
        }
        elseif ($Results -isnot [array]) {
            $Results = @($Results)
        }
        
        # Debug property names - helpful for understanding what properties are available
        if ($Results.Count -gt 0) {
            $firstResult = $Results[0]
            Write-Log -Message "Properties available in result object: $($firstResult.PSObject.Properties.Name -join ', ')" -Level 'INFO'
        }
        
        # Initialize category counts with proper tracking
        $categoryCounts = @{
            "Ready" = 0
            "CPU Incompatible" = 0
            "Storage Issues" = 0
            "Requires Intermediate Upgrade" = 0 
            "Multiple Issues" = 0
            "Failed to Check" = 0
            "Already Up-To-Date" = 0
        }
        
        # Accurately count hosts in each category
        foreach ($esxiHost in $Results) {
            # Get the actual category
            $category = $esxiHost.UpgradeReadinessCategory
            
            # Increment the appropriate counter
            if ($categoryCounts.ContainsKey($category)) {
                $categoryCounts[$category]++
            }
            else {
                # Default to Multiple Issues if category not recognized
                $categoryCounts["Multiple Issues"]++
            }
        }
        
        $totalHosts = $Results.Count
        $readyHosts = $categoryCounts["Ready"]
        $alreadyUpToDateHosts = $categoryCounts["Already Up-To-Date"]
        $notReadyHosts = $totalHosts - $readyHosts - $alreadyUpToDateHosts
        
        # Get target version details
        $targetVersionDetail = ($Results | Where-Object { $_.TargetVersionDetail } | Select-Object -First 1).TargetVersionDetail
        if (-not $targetVersionDetail) {
            $targetVersionDetail = "ESXi $TargetESXiVersion"
        }
        
        # Generate HTML
        $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ESXi Upgrade Readiness Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background-color: #fff;
            padding: 20px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
            border-radius: 5px;
        }
        h1, h2, h3 {
            color: #2c3e50;
        }
        .header {
            border-bottom: 2px solid #eee;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }
        .target-version {
            font-size: 1.1rem;
            color: #333;
            margin-bottom: 15px;
            background-color: #e9f7fe;
            padding: 10px;
            border-radius: 5px;
            border-left: 4px solid #3498db;
        }
        .summary {
            display: flex;
            flex-wrap: wrap;
            gap: 20px;
            margin-bottom: 30px;
        }
        .summary-card {
            flex: 1;
            min-width: 200px;
            background-color: #fff;
            border-radius: 5px;
            box-shadow: 0 0 5px rgba(0,0,0,0.1);
            padding: 15px;
            text-align: center;
        }
        .ready {
            background-color: #d4edda;
            color: #155724;
        }
        .not-ready {
            background-color: #f8d7da;
            color: #721c24;
        }
        .up-to-date {
            background-color: #d1ecf1;
            color: #0c5460;
        }
        .chart-container {
            display: flex;
            gap: 20px;
            margin-bottom: 30px;
        }
        .pie-chart {
            width: 48%;
        }
        .categories {
            width: 48%;
        }
        .category {
            margin-bottom: 10px;
            padding: 10px;
            border-radius: 5px;
        }
        .category-already {
            background-color: #17a2b8;
            color: white;
        }
        .category-ready {
            background-color: #28a745;
            color: white;
        }
        .category-cpu {
            background-color: #dc3545;
            color: white;
        }
        .category-storage {
            background-color: #ffc107;
            color: #333;
        }
        .category-upgrade {
            background-color: #17a2b8;
            color: white;
        }
        .category-multiple {
            background-color: #6c757d;
            color: white;
        }
        .category-failed {
            background-color: #343a40;
            color: white;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 20px;
        }
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #f8f9fa;
            font-weight: 600;
            position: sticky;
            top: 0;
        }
        tr:hover {
            background-color: #f1f1f1;
        }
        .section {
            margin-bottom: 30px;
        }
        .status-ready {
            color: #28a745;
            font-weight: bold;
        }
        .status-notready {
            color: #dc3545;
            font-weight: bold;
        }
        .status-warning {
            color: #ffc107;
            font-weight: bold;
        }
        .status-uptodate {
            color: #17a2b8;
            font-weight: bold;
        }
        .hidden {
            display: none;
        }
        .filters {
            margin-bottom: 20px;
            padding: 15px;
            background-color: #f8f9fa;
            border-radius: 5px;
        }
        .filter-btn {
            background-color: #6c757d;
            color: white;
            border: none;
            padding: 8px 12px;
            border-radius: 4px;
            cursor: pointer;
            margin-right: 5px;
            margin-bottom: 5px;
        }
        .filter-btn:hover {
            background-color: #5a6268;
        }
        .filter-btn.active {
            background-color: #007bff;
        }
        .timestamp {
            font-size: 0.8rem;
            color: #6c757d;
            text-align: right;
            margin-top: 5px;
        }
        .host-details {
            cursor: pointer;
        }
        .detail-row {
            background-color: #f8f9fa;
            display: none;
        }
        .detail-content {
            padding: 15px;
        }
        .badges {
            display: flex;
            gap: 5px;
            flex-wrap: wrap;
        }
        .badge {
            padding: 3px 8px;
            border-radius: 12px;
            font-size: 0.8rem;
            font-weight: bold;
        }
        .badge-success {
            background-color: #d4edda;
            color: #155724;
        }
        .badge-danger {
            background-color: #f8d7da;
            color: #721c24;
        }
        .badge-warning {
            background-color: #fff3cd;
            color: #856404;
        }
        .badge-info {
            background-color: #d1ecf1;
            color: #0c5460;
        }
        .cpu-status {
            font-weight: bold;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .cpu-compatible {
            color: #28a745;
        }
        .cpu-incompatible {
            color: #dc3545;
        }
        .cpu-unknown {
            color: #ffc107;
        }
        .search-box {
            width: 100%;
            padding: 10px;
            margin-bottom: 15px;
            border: 1px solid #ddd;
            border-radius: 4px;
            font-size: 16px;
        }
        .cpu-icon {
            font-size: 1.2rem;
            margin-right: 3px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>ESXi Upgrade Readiness Report</h1>
            <div class="target-version">
                <strong>Target Version:</strong> $targetVersionDetail
            </div>
            <div class="timestamp">Report generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</div>
        </div>
        
        <div class="summary">
            <div class="summary-card">
                <h3>Total Hosts</h3>
                <p style="font-size: 24px;">$totalHosts</p>
            </div>
            <div class="summary-card ready">
                <h3>Ready for Upgrade</h3>
                <p style="font-size: 24px;">$readyHosts</p>
            </div>
            <div class="summary-card up-to-date">
                <h3>Already Up-To-Date</h3>
                <p style="font-size: 24px;">$alreadyUpToDateHosts</p>
            </div>
            <div class="summary-card not-ready">
                <h3>Not Ready</h3>
                <p style="font-size: 24px;">$notReadyHosts</p>
            </div>
        </div>
        
        <div class="chart-container">
            <div class="pie-chart">
                <h2>Upgrade Readiness Overview</h2>
                <canvas id="readinessChart" width="400" height="300"></canvas>
            </div>
            
            <div class="categories">
                <h2>Categories Breakdown</h2>
"@

        # Add category bars to HTML with accurate percentages
        $categoryClasses = @{
            "Ready" = "category-ready"
            "CPU Incompatible" = "category-cpu"
            "Storage Issues" = "category-storage"
            "Requires Intermediate Upgrade" = "category-upgrade"
            "Multiple Issues" = "category-multiple"
            "Failed to Check" = "category-failed"
            "Already Up-To-Date" = "category-already"
        }
        
        foreach ($category in $categoryCounts.Keys) {
            $count = $categoryCounts[$category]
            $percentage = if ($totalHosts -gt 0) { [math]::Round(($count / $totalHosts) * 100, 1) } else { 0 }
            $categoryClass = $categoryClasses[$category]
            
            $htmlContent += @"
                <div class="category $categoryClass">
                    $category : $count ($percentage%)
                </div>
"@
        }
        
        # Continue with filters and table - enhanced with better CPU status display
        $htmlContent += @"
            </div>
        </div>
        
        <div class="section">
            <h2>Hosts by Category</h2>
            
            <div class="filters">
                <strong>Filter by:</strong><br>
                <button class="filter-btn active" data-filter="all">All ($totalHosts)</button>
                <button class="filter-btn" data-filter="Ready">Ready ($($categoryCounts["Ready"]))</button>
                <button class="filter-btn" data-filter="Already Up-To-Date">Up-To-Date ($($categoryCounts["Already Up-To-Date"]))</button>
                <button class="filter-btn" data-filter="CPU Incompatible">CPU Incompatible ($($categoryCounts["CPU Incompatible"]))</button>
                <button class="filter-btn" data-filter="Storage Issues">Storage Issues ($($categoryCounts["Storage Issues"]))</button>
                <button class="filter-btn" data-filter="Requires Intermediate Upgrade">Requires Upgrade ($($categoryCounts["Requires Intermediate Upgrade"]))</button>
                <button class="filter-btn" data-filter="Multiple Issues">Multiple Issues ($($categoryCounts["Multiple Issues"]))</button>
                <button class="filter-btn" data-filter="Failed to Check">Failed ($($categoryCounts["Failed to Check"]))</button>
            </div>
            
            <input type="text" id="searchBox" class="search-box" placeholder="Search for hosts, CPUs, versions...">
            
            <table id="hostsTable">
                <thead>
                    <tr>
                        <th>Host Name</th>
                        <th>Current Version</th>
                        <th>CPU Status</th>
                        <th>Processor Type</th>
                        <th>Status</th>
                        <th>Actions</th>
                    </tr>
                </thead>
                <tbody>
"@
        
        # Add table rows with enhanced version display and CPU status icons
        foreach ($esxiHost in $Results) {
            # Safe property access with defaults
            $hasUpgradeReadiness = $esxiHost.PSObject.Properties.Name -contains "UpgradeReadiness"
            $upgradeReadiness = if ($hasUpgradeReadiness) { $esxiHost.UpgradeReadiness } else { "Unknown" }
            
            $hasCPUCompatible = $esxiHost.PSObject.Properties.Name -contains "CPUCompatible"
            $cpuCompatible = if ($hasCPUCompatible) { $esxiHost.CPUCompatible } else { $false }
            
            $cpuStatusClass = if ($cpuCompatible -eq $true) {
                "cpu-compatible"
            } elseif ($cpuCompatible -eq $false) {
                "cpu-incompatible"
            } else {
                "cpu-unknown"
            }
            
            # Get CPU icon or default to something if not available
            $cpuStatusIcon = "?"
            if ($esxiHost.PSObject.Properties.Name -contains "CPUCompatibilityIcon") {
                $cpuStatusIcon = $esxiHost.CPUCompatibilityIcon
            }
            elseif ($cpuCompatible -eq $true) {
                $cpuStatusIcon = "√"
            }
            elseif ($cpuCompatible -eq $false) {
                $cpuStatusIcon = "X"
            }
            
            $hasVersion = $esxiHost.PSObject.Properties.Name -contains "Version"
            $version = if ($hasVersion) { $esxiHost.Version } else { "Unknown" }
            
            # Show detailed version if available
            $versionDisplay = $version
            if ($esxiHost.PSObject.Properties.Name -contains "VersionDetail" -and -not [string]::IsNullOrWhiteSpace($esxiHost.VersionDetail)) {
                $versionDisplay = "$version - $($esxiHost.VersionDetail)"
            }
            elseif ($esxiHost.PSObject.Properties.Name -contains "Build") {
                $versionDisplay = "$version (Build $($esxiHost.Build))"
            }
            
            $hasProcessorType = $esxiHost.PSObject.Properties.Name -contains "ProcessorType"
            $processorType = if ($hasProcessorType) { $esxiHost.ProcessorType } else { "Unknown" }
            
            # Set the status class based on readiness
            $statusClass = switch ($upgradeReadiness) {
                "Ready for Upgrade" { "status-ready" }
                "Already Up-To-Date" { "status-uptodate" }
                "Failed to Check" { "status-warning" }
                default { "status-notready" }
            }
            
            # For storage, check multiple possible property names
            $storageReady = $false
            if ($esxiHost.PSObject.Properties.Name -contains "StorageReady") {
                $storageReady = $esxiHost.StorageReady
            }
            elseif ($esxiHost.PSObject.Properties.Name -contains "SufficientFreeSpace") {
                $storageReady = $esxiHost.SufficientFreeSpace
            }
            
            $hasDirectUpgrade = $esxiHost.PSObject.Properties.Name -contains "DirectUpgradePossible"
            $directUpgradePossible = if ($hasDirectUpgrade) { $esxiHost.DirectUpgradePossible } else { $false }
            
            $htmlContent += @"
                <tr class="host-row" data-category="$($esxiHost.UpgradeReadinessCategory)">
                    <td>$($esxiHost.HostName)</td>
                    <td>$versionDisplay</td>
                    <td class="cpu-status $cpuStatusClass"><span class="cpu-icon">$cpuStatusIcon</span></td>
                    <td>$processorType</td>
                    <td class="$statusClass">$upgradeReadiness</td>
                    <td><button class="host-details" data-host="$($esxiHost.HostName)">Details</button></td>
                </tr>
                <tr id="details-$($esxiHost.HostName)" class="detail-row">
                    <td colspan="6">
                        <div class="detail-content">
                            <h3>Details for $($esxiHost.HostName)</h3>
                            <div class="badges">
"@
            
            # Add badges for status indicators with enhanced information
            $cpuBadgeClass = if ($cpuCompatible) { 'badge-success' } else { 'badge-danger' }
            $storageBadgeClass = if ($storageReady) { 'badge-success' } else { 'badge-danger' }
            $upgradeBadgeClass = if ($directUpgradePossible) { 'badge-success' } else { 'badge-warning' }
            $alreadyUpToDateClass = if ($esxiHost.PSObject.Properties.Name -contains "AlreadyUpToDate" -and $esxiHost.AlreadyUpToDate) { 'badge-info' } else { 'badge-none' }
            
            $htmlContent += @"
                                <span class="badge $cpuBadgeClass">CPU: $($cpuCompatible ? 'Compatible' : 'Incompatible')</span>
                                <span class="badge $storageBadgeClass">Storage: $($storageReady ? 'Ready' : 'Issues')</span>
                                <span class="badge $upgradeBadgeClass">Upgrade Path: $($directUpgradePossible ? 'Direct' : 'Requires Steps')</span>
"@

            # Add "Already Up-To-Date" badge if applicable
            if ($esxiHost.PSObject.Properties.Name -contains "AlreadyUpToDate" -and $esxiHost.AlreadyUpToDate) {
                $htmlContent += @"
                                <span class="badge badge-info">Already Up-To-Date</span>
"@
            }

            $htmlContent += @"
                            </div>
                            
                            <h4>System Information</h4>
                            <ul>
"@

            # Only add properties that exist
            if ($esxiHost.PSObject.Properties.Name -contains "Manufacturer") {
                $htmlContent += "<li><strong>Manufacturer:</strong> $($esxiHost.Manufacturer)</li>"
            }
            
            if ($esxiHost.PSObject.Properties.Name -contains "Model") {
                $htmlContent += "<li><strong>Model:</strong> $($esxiHost.Model)</li>"
            }
            
            if ($hasVersion) {
                $htmlContent += "<li><strong>Version:</strong> $versionDisplay</li>"
            }
            
            if ($esxiHost.PSObject.Properties.Name -contains "InstallDate") {
                $htmlContent += "<li><strong>Install Date:</strong> $($esxiHost.InstallDate)</li>"
            }
            
            # Add CPU compatibility notes if available
            if ($esxiHost.PSObject.Properties.Name -contains "CPUCompatibilityNotes" -and 
                -not [string]::IsNullOrWhiteSpace($esxiHost.CPUCompatibilityNotes)) {
                $htmlContent += "<li><strong>CPU Compatibility:</strong> $($esxiHost.CPUCompatibilityNotes)</li>"
            }
            
            # Add storage issues if available
            if ($esxiHost.PSObject.Properties.Name -contains "StorageIssues" -and 
                $esxiHost.StorageIssues -and $esxiHost.StorageIssues.Count -gt 0) {
                $htmlContent += "<li><strong>Storage Issues:</strong> $($esxiHost.StorageIssues -join '; ')</li>"
            }
            
            # Add upgrade path info (enhanced with more details)
            if ($esxiHost.PSObject.Properties.Name -contains "UpgradePathNotes" -and 
                -not [string]::IsNullOrWhiteSpace($esxiHost.UpgradePathNotes)) {
                $htmlContent += "<li><strong>Upgrade Path:</strong> $($esxiHost.UpgradePathNotes)</li>"
            }
            
            # Add recommended upgrade path if available
            if ($esxiHost.PSObject.Properties.Name -contains "RecommendedPath" -and 
                -not [string]::IsNullOrWhiteSpace($esxiHost.RecommendedPath)) {
                $htmlContent += "<li><strong>Recommended Action:</strong> $($esxiHost.RecommendedPath)</li>"
            }
            
            $htmlContent += @"
                            </ul>
                        </div>
                    </td>
                </tr>
"@
        }
        
        # Finalize HTML document with JavaScript - fix the chart tooltip to avoid $value error
        $htmlContent += @"
                </tbody>
            </table>
        </div>
    </div>
    
    <script src="https://cdn.jsdelivr.net/npm/chart.js@3.7.1/dist/chart.min.js"></script>
    <script>
        // Chart.js initialization
        document.addEventListener('DOMContentLoaded', function() {
            // Pie chart for readiness
            const readinessCtx = document.getElementById('readinessChart').getContext('2d');
            const readinessChart = new Chart(readinessCtx, {
                type: 'doughnut',
                data: {
                    labels: ['Ready for Upgrade', 'Already Up-To-Date', 'Not Ready'],
                    datasets: [{
                        data: [$readyHosts, $alreadyUpToDateHosts, $notReadyHosts],
                        backgroundColor: ['#28a745', '#17a2b8', '#dc3545'],
                        borderColor: ['#1e7e34', '#138496', '#bd2130'],
                        borderWidth: 1
                    }]
                },
                options: {
                    responsive: true,
                    plugins: {
                        legend: {
                            position: 'bottom',
                        },
						tooltip: {
							callbacks: {
								label: function(context) {
									var label = context.label || '';
									var currentValue = context.parsed || 0;
									var total = context.dataset.data.reduce(function(acc, val) { return acc + val; }, 0);
									var percentage = Math.round((currentValue / total) * 100);
									return label + ': ' + currentValue + ' (' + percentage + '%)';
								}
							}
						}
                    }
                }
            });
            
            // Filter functionality
            const filterButtons = document.querySelectorAll('.filter-btn');
            const hostRows = document.querySelectorAll('.host-row');
            const searchBox = document.getElementById('searchBox');
            
            filterButtons.forEach(button => {
                button.addEventListener('click', function() {
                    const filter = this.getAttribute('data-filter');
                    
                    // Update active button
                    filterButtons.forEach(btn => btn.classList.remove('active'));
                    this.classList.add('active');
                    
                    // Filter table rows based on both filter and search
                    applyFiltersAndSearch();
                });
            });
            
            // Search functionality
            searchBox.addEventListener('input', function() {
                applyFiltersAndSearch();
            });
            
            function applyFiltersAndSearch() {
                const activeFilter = document.querySelector('.filter-btn.active').getAttribute('data-filter');
                const searchTerm = searchBox.value.toLowerCase();
                
                hostRows.forEach(row => {
                    const hostName = row.cells[0].textContent.toLowerCase();
                    const version = row.cells[1].textContent.toLowerCase();
                    const cpuType = row.cells[3].textContent.toLowerCase();
                    const status = row.cells[4].textContent.toLowerCase();
                    const category = row.getAttribute('data-category');
                    
                    const matchesFilter = activeFilter === 'all' || category === activeFilter;
                    const matchesSearch = searchTerm === '' || 
                                        hostName.includes(searchTerm) || 
                                        version.includes(searchTerm) || 
                                        cpuType.includes(searchTerm) ||
                                        status.includes(searchTerm);
                    
                    if (matchesFilter && matchesSearch) {
                        row.classList.remove('hidden');
                    } else {
                        row.classList.add('hidden');
                        
                        // Hide details row if parent is hidden
                        const hostNameRaw = row.cells[0].textContent;
                        const detailsRow = document.getElementById('details-' + hostNameRaw);
                        if (detailsRow) {
                            detailsRow.style.display = 'none';
                        }
                    }
                });
            }
            
            // Host details functionality
            const detailButtons = document.querySelectorAll('.host-details');
            
            detailButtons.forEach(button => {
                button.addEventListener('click', function() {
                    const hostName = this.getAttribute('data-host');
                    const detailRow = document.getElementById('details-' + hostName);
                    
                    if (detailRow.style.display === 'table-row') {
                        detailRow.style.display = 'none';
                    } else {
                        detailRow.style.display = 'table-row';
                    }
                });
            });
        });
    </script>
</body>
</html>
"@
        
        # Write HTML to file
        $htmlContent | Out-File -FilePath $ReportPath -Encoding UTF8
        
        Write-Log -Message "HTML report generated: $ReportPath" -Level 'SUCCESS'
        return $true
    }
    catch {
        Write-Log -Message "Failed to generate HTML report: $_" -Level 'ERROR'
        return $false
    }
}

#endregion

#region Main Execution

# Initialize log
Write-Log -Message "========== ESXi Upgrade Readiness Assessment Tool ==========" -Level 'INFO'
Write-Log -Message "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level 'INFO'

try {
    # Initialize summary tracking
    Initialize-Summary
    
    # Load configuration
    $config = Get-Configuration
    $creds = $config.Credential
    $targetVersion = $config.TargetESXiVersion
    $targetESXiBuild = $config.TargetESXiBuild
    $targetESXiDetail = $config.TargetESXiDetail
    $minRequiredSpaceGB = $config.MinimumRequiredSpaceGB
    $minBootbankFreePercentage = $config.MinimumBootbankFreePercentage
    
    Write-Log -Message "Target ESXi version: $targetVersion (Build $targetESXiBuild - $targetESXiDetail)" -Level 'INFO'
    Write-Log -Message "Minimum required space (GB): $minRequiredSpaceGB" -Level 'INFO'
    Write-Log -Message "Minimum bootbank free percentage: $minBootbankFreePercentage" -Level 'INFO'
    
    # Initialize PowerCLI
    Initialize-PowerCLI
    
    # Get list of hosts to process
    $targetHosts = Get-TargetServers -Servers $Servers -ServerListFile $ServerListFile -NameMatch $NameMatch
    
    if ($targetHosts.Count -eq 0) {
        Write-Log -Message "No hosts found to process. Please check your input parameters." -Level 'WARNING'
        return
    }
    
    Write-Log -Message "Found $($targetHosts.Count) hosts to process" -Level 'INFO'
    $script:Summary.TotalHosts = $targetHosts.Count
    
    # Process hosts
    $results = @()

    if ($Parallel) {
        Write-Log -Message "Processing hosts in parallel (max $MaxConcurrentJobs concurrent jobs)" -Level 'INFO'
        
        # Define Write-FailureLog function for the jobs
        $writeFailureLogFunction = @'
function Write-FailureLog {
    param(
        [string]$HostName,
        [string]$Reason,
        [string]$IPAddress = ""
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp - Failed to connect to host: $HostName"
    if ($IPAddress) {
        $logEntry += " (IP: $IPAddress)"
    }
    $logEntry += " - Reason: $Reason"
    
    # Just output to the console
    Write-Output "FAILURE: $logEntry"
}
'@

		$writeLogFunction = @'
function Write-JobLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # Just output to the console, don't try to write to a file
    Write-Output "[$timestamp] [$Level] [Job] $Message"
}
'@
        
		# Build a single string containing all function definitions
		#$allFunctionDefs = $writeFailureLogFunction + "`n`n" + $writeLogFunction + "`n`n"
		$allFunctionDefs = @()
		
		# Add the regular functions - important to use this format to maintain proper function structure
		$functions = @(
			'write-log',
			'Write-FailureLog',
			'Connect-ESXiHost',
			'Get-ESXiHostInfo',
			'Get-ESXiImageProfile',
			'Get-ESXiInstallDate',
			'Get-ESXiSystemTime',
			'Get-ESXiFilesystemInfo',
			'Get-ESXiHardwareInfo',
			'Get-ESXiAssetTag',
			'Get-ESXiNetworkInfo',
			'Test-CPUCompatibility',
			'Test-StorageReadiness',
			'Test-DirectUpgradePathAvailable',
			'Get-UpgradePathInfo',
			'Get-UpgradeReadinessCategory',
			'Get-ESXiReleaseInfo',
			'Analyze-ESXiHost'
		)
		
		foreach ($function in $functions) {
			$functionContent = Get-Item "Function:\$function" | Select-Object -ExpandProperty ScriptBlock
			$allFunctionDefs += "function $function {`n$functionContent`n}`n`n"
		}
		
		# Create the script block with the Analyze-ESXiHostInJob function
		$scriptBlock = {
			param(
				[string]$HostName,
				[string]$IPAddress,
				[PSCredential]$Credential,
				[string]$TargetVersion,
				[string]$TargetESXiBuild,
				[string]$TargetESXiDetail,
				[double]$MinRequiredSpaceGB,
				[double]$MinBootbankFreePercentage,
				[string]$FunctionDefinitions
			)
			
			# Load all the functions
			. ([ScriptBlock]::Create($FunctionDefinitions))
			
			# Configure PowerCLI
			try {
				Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
				Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
				Write-Log -Message "PowerCLI configuration set successfully" -Level 'INFO'
			}
			catch {
				Write-Log -Message "Error configuring PowerCLI: $_" -Level 'ERROR'
			}
            
            # Run the analysis
			return Analyze-ESXiHost -HostName $HostName -IPAddress $IPAddress -Credential $Credential -TargetVersion $TargetVersion -TargetESXiBuild $TargetESXiBuild -TargetESXiDetail $TargetESXiDetail -MinimumRequiredSpaceGB $MinRequiredSpaceGB -MinimumBootbankFreePercentage $MinBootbankFreePercentage
        }
        
		# Start jobs with throttling
		$jobs = @()
		$runningJobs = @()

		for ($i = 0; $i -lt $targetHosts.Count; $i++) {
			$currentServer = $targetHosts[$i]
			Write-ProgressUpdate -Current $i -Total $targetHosts.Count -Status "Starting job for $($currentServer.HostName)"

			while ($runningJobs.Count -ge $MaxConcurrentJobs) {
				$completedJobs = $runningJobs | Where-Object { $_.State -ne "Running" }
				foreach ($job in $completedJobs) {
					$runningJobs = $runningJobs | Where-Object { $_ -ne $job }
				}

				if ($runningJobs.Count -ge $MaxConcurrentJobs) {
					Start-Sleep -Seconds 2
				}
			}

			$job = Start-Job -Name $currentServer.HostName -ScriptBlock $scriptBlock -ArgumentList $currentServer.HostName, $currentServer.IPAddress, $creds, $targetVersion, $targetESXiBuild, $targetESXiDetail, $minRequiredSpaceGB, $minBootbankFreePercentage, $allFunctionDefs
			$jobs += $job
			$runningJobs += $job
		}

		# Enhanced waiting loop for all jobs to complete
		$totalJobs = $jobs.Count
		$completedJobs = 0
		$jobStatus = @{}

		while ($completedJobs -lt $totalJobs) {
			foreach ($job in $jobs) {
				try {
					$jobState = $job.State
				} catch {
					Write-Log -Message "Failed to get job state for job ID $($job.Id): $_" -Level 'ERROR'
					continue
				}

				$hostName = $job.Name
				if (-not $jobStatus.ContainsKey($job.Id)) {
					$jobStatus[$job.Id] = $jobState
				}

				if ($jobState -ne $jobStatus[$job.Id]) {
					$jobStatus[$job.Id] = $jobState

					switch ($jobState) {
						'Running' {
							Write-Log -Message "Job [$hostName] is running..." -Level 'INFO'
						}
						'Completed' {
							try {
								$jobResult = Receive-Job -Job $job -ErrorAction Stop -Wait
								$jobLogMessages = $jobResult | Where-Object { $_ -is [string] -and $_ -match '^[\[]\d{4}-\d{2}-\d{2}' }
								foreach ($message in $jobLogMessages) {
									Write-Host $message
								}

								$hostResult = $jobResult | Where-Object { $_ -is [PSCustomObject] -and $_.PSObject.Properties.Name -contains 'HostName' } | Select-Object -Last 1
								if ($hostResult) {
									$results += $hostResult

									if ($hostResult.UpgradeReadiness -eq "Ready for Upgrade") {
										$script:Summary.ReadyForUpgrade++
										$script:Summary.Categories["Ready"] += $hostResult.HostName
									}
									elseif ($hostResult.UpgradeReadiness -eq "Already Up-To-Date") {
										$script:Summary.AlreadyUpToDate++
										$script:Summary.Categories["Already Up-To-Date"] += $hostResult.HostName
									}
									elseif ($hostResult.UpgradeReadiness -eq "Failed to Check") {
										$script:Summary.FailedToCheck++
										$script:Summary.Categories["Failed to Check"] += $hostResult.HostName
									}
									else {
										$script:Summary.NotReadyForUpgrade++
										$script:Summary.Categories[$hostResult.UpgradeReadinessCategory] += $hostResult.HostName
									}

									Write-Log -Message "Successfully processed job result for host: $($hostResult.HostName)" -Level 'INFO'
								}
								else {
									throw "No valid host result found"
								}
							} catch {
								Write-Log -Message "Error receiving job result for host $hostName - $_" -Level 'ERROR'
								$failedResult = [PSCustomObject]@{
									HostName = $hostName
									IPAddress = ($targetHosts | Where-Object { $_.HostName -eq $hostName }).IPAddress
									UpgradeReadiness = "Failed to Check"
									UpgradeReadinessCategory = "Failed to Check"
									CPUCompatibilityIcon = "❓"
								}
								$results += $failedResult
								$script:Summary.FailedToCheck++
								$script:Summary.Categories["Failed to Check"] += $failedResult.HostName
							}

							Remove-Job -Job $job -Force
							$completedJobs++
						}
						'Failed' {
							Write-Log -Message "Job [$hostName] failed" -Level 'ERROR'
							$failedResult = [PSCustomObject]@{
								HostName = $hostName
								IPAddress = ($targetHosts | Where-Object { $_.HostName -eq $hostName }).IPAddress
								UpgradeReadiness = "Failed to Check"
								UpgradeReadinessCategory = "Failed to Check"
								CPUCompatibilityIcon = "❓"
							}
							$results += $failedResult
							$script:Summary.FailedToCheck++
							$script:Summary.Categories["Failed to Check"] += $failedResult.HostName
							Remove-Job -Job $job -Force
							$completedJobs++
						}
					}
				}
			}

			Write-Progress -Activity "ESXi Upgrade Job Monitor" -Status "$completedJobs / $totalJobs jobs completed" -PercentComplete ([math]::Round(($completedJobs / $totalJobs) * 100))
			Start-Sleep -Seconds 1
		}
	}

    else {
        # Process hosts sequentially
        for ($i = 0; $i -lt $targetHosts.Count; $i++) {
            $currentServer = $targetHosts[$i]
            Write-ProgressUpdate -Current $i -Total $targetHosts.Count -Status "Processing host $($currentServer.HostName)"
            
            $hostResult = Analyze-ESXiHost -HostName $currentServer.HostName -IPAddress $currentServer.IPAddress -Credential $creds -TargetVersion $targetVersion -TargetESXiBuild $targetESXiBuild -TargetESXiDetail $targetESXiDetail -MinimumRequiredSpaceGB $minRequiredSpaceGB -MinimumBootbankFreePercentage $minBootbankFreePercentage
            $results += $hostResult
            
            # Update summary stats
            if ($hostResult.UpgradeReadiness -eq "Ready for Upgrade") {
                $script:Summary.ReadyForUpgrade++
                $script:Summary.Categories["Ready"] += $hostResult.HostName
            }
            elseif ($hostResult.UpgradeReadiness -eq "Already Up-To-Date") {
                $script:Summary.AlreadyUpToDate++
                $script:Summary.Categories["Already Up-To-Date"] += $hostResult.HostName
            }
            elseif ($hostResult.UpgradeReadiness -eq "Failed to Check") {
                $script:Summary.FailedToCheck++
                $script:Summary.Categories["Failed to Check"] += $hostResult.HostName
            }
            else {
                $script:Summary.NotReadyForUpgrade++
                $script:Summary.Categories[$hostResult.UpgradeReadinessCategory] += $hostResult.HostName
            }
        }
    }
    
    # Export results
    if ($results.Count -gt 0) {
        Export-ResultsToCSV -Results $results -CsvPath $OutputCsv
        Generate-HTMLReport -Results $results -ReportPath $ReportPath -TargetESXiVersion $targetVersion
        
        # Display summary
        Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
        Write-Host "Total hosts processed: $($script:Summary.TotalHosts)" -ForegroundColor White
        Write-Host "Ready for upgrade: $($script:Summary.ReadyForUpgrade)" -ForegroundColor Green
        Write-Host "Already up-to-date: $($script:Summary.AlreadyUpToDate)" -ForegroundColor Cyan
        Write-Host "Not ready for upgrade: $($script:Summary.NotReadyForUpgrade)" -ForegroundColor Yellow
        Write-Host "Failed to check: $($script:Summary.FailedToCheck)" -ForegroundColor Red
        
        Write-Host "`nCategory breakdown:" -ForegroundColor Cyan
        foreach ($category in $script:Summary.Categories.Keys) {
            $count = $script:Summary.Categories[$category].Count
            if ($count -gt 0) {
                $color = switch ($category) {
                    "Ready" { "Green" }
                    "Already Up-To-Date" { "Cyan" }
                    "Failed to Check" { "Red" }
                    default { "Yellow" }
                }
                Write-Host "  $category`: $count" -ForegroundColor $color
            }
        }
        
        Write-Host "`nOutput files:" -ForegroundColor Cyan
        Write-Host "  CSV report: $OutputCsv" -ForegroundColor White
        Write-Host "  HTML report: $ReportPath" -ForegroundColor White
        Write-Host "  Log file: $($script:LogFile)" -ForegroundColor White
        if (Test-Path $script:FailureLogFile) {
            Write-Host "  Failure log: $($script:FailureLogFile)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Log -Message "No results were generated" -Level 'WARNING'
    }
}
catch {
    Write-Log -Message "Critical error: $_" -Level 'ERROR'
    Write-Log -Message $_.ScriptStackTrace -Level 'ERROR'
    
    Write-Host "`nCritical error occurred. See log file for details: $($script:LogFile)" -ForegroundColor Red
}
finally {
    Write-Log -Message "Finished at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level 'INFO'
    Write-Log -Message "==================== End of Log ====================" -Level 'INFO'
}

#endregion
