﻿<#
    .SYNOPSIS
    This script automates the installation and configuration of the Zabbix Agent on a Windows machine.

    .DESCRIPTION
    The script ensures all required dependencies are met, downloads the correct version of the Zabbix Agent, 
    stops and starts the Zabbix service, and updates its configuration file. It includes functions to handle 
    service management, package installation, and configuration updates.

    .PARAMETER ZabbixServer
    The IP address of the Zabbix server.

    .PARAMETER ZabbixServerActive
    The IP address for active Zabbix server checks.

    .PARAMETER ListenPort
    The port on which the Zabbix agent listens. Default is '10050'.

    .PARAMETER EnablePath
    Enables or disables the Path for the system.run[] key. Default is '1'.

    .PARAMETER AllowDenyKey
    Specifies allowed keys for the Zabbix agent. Default is 'AllowKey=system.run[*]'.

    .PARAMETER HostMetaData
    Metadata for the host. Default is 'Windows clients'.

    .EXAMPLE
    .\Install-ZabbixAgent-Intune.ps1
    Powershell -ExecutionPolicy ByPass -File "\\FQDN\SHARE\Install-ZabbixAgent-Intune.ps1"

    .INPUTS
    None. The script does not accept pipeline input.

    .OUTPUTS
    Outputs status messages to the console during execution.

    .NOTES
        FunctionName : Install-ZabbixAgent-Intune
        Created by   : RoBeDi
        Date Coded   : 06/17/2024 08:17:41
    .LINK
        https://github.com/RoBeDi/PowerShell
 #>


[CmdletBinding()]
param (
[Parameter()]
[string]$ZabbixServer = '[Zabbix_Server_IP]',
[Parameter()]
[string]$ZabbixServerActive = '[Zabbix_Server_IP]',
[Parameter()]
[string]$ListenPort = '10050',
[Parameter()]
[string]$EnablePath = '1',
[Parameter()]
[string]$AllowDenyKey = 'AllowKey=system.run[*]',
[Parameter()]
[string]$HostMetaData = 'Windows clients'
)

cls
$HostInterface = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.AddressState -eq "Preferred" -and ($_.ValidLifetime -lt "24:00:00" -or $_.PrefixOrigin -eq "Dhcp") }).IPAddress
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$Model = $osInfo.ProductType
$ServiceName = 'Zabbix Agent'
$version = "7.0.4"
$AgentConfFile = "C:\Program Files\Zabbix Agent\zabbix_agentd.conf"
$destinationFilePath = "C:\Program Files\Zabbix Agent\template_zabbix_agentd.conf"

function Stop-ZabbixAgentService {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ServiceName
    )
    
    # Check if the service exists
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-Host "Service $ServiceName does not exist. Skipping..." -ForegroundColor Red
        return
    }
    
    # Stop the service
    Write-Host "Stopping the service: $ServiceName"
    Stop-Service -Name $ServiceName -Force

    # Confirm the service has stopped
    $service = Get-Service -Name $ServiceName
    while ($service.Status -ne 'Stopped') {
        Write-Host "Waiting for service to stop..."
        Start-Sleep -Seconds 2
        $service = Get-Service -Name $ServiceName
    }
    Write-Host "Service $ServiceName has stopped."
}

function Start-ZabbixAgentService {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ServiceName
    )
    
    # Start the service
    Write-Host "Starting the service: $ServiceName"
    Start-Service -Name $ServiceName

    # Confirm the service has started
    $service = Get-Service -Name $ServiceName
    while ($service.Status -ne 'Running') {
        Write-Host "Waiting for service to start..."
        Start-Sleep -Seconds 2
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
        $service = Get-Service -Name $ServiceName
    }
    Write-Host "Service $ServiceName is running."
}

function Ensure-Module {
    param (
        [string]$ModuleName
    )

    # Check if the module is installed
    $module = Get-Module -ListAvailable -Name $ModuleName
    if ($null -eq $module) {
        Write-Output "Module $ModuleName is not installed. Installing..."
        Install-Module -Name $ModuleName -Force -AllowClobber
    } else {
        # Get the latest version of the module from the online gallery
        $latestModule = Find-Module -Name $ModuleName
        $latestVersion = $latestModule.Version
        $installedVersion = $module.Version

        # Check if the module was installed using Install-Module
        $installSource = (Get-InstalledModule -Name $ModuleName -ErrorAction SilentlyContinue)

        # If the module was not installed via Install-Module, uninstall it first
        if ($null -eq $installSource) {
            Write-Output "Module $ModuleName was not installed via Install-Module. Uninstalling and reinstalling the latest version..."
            # Uninstall the existing module first
            Remove-Module -Name $ModuleName -Force -ErrorAction SilentlyContinue
            Uninstall-Module -Name $ModuleName -AllVersions -Force -ErrorAction SilentlyContinue

            # Install the latest version of the module
            Install-Module -Name $ModuleName -Force -AllowClobber
        } else {
            # Compare installed version with the latest version
            if ($installedVersion -lt $latestVersion) {
                Write-Output "Updating module $ModuleName from version $installedVersion to version $latestVersion..."
                Update-Module -Name $ModuleName -Force
            } else {
                Write-Output "Module $ModuleName is already up-to-date (version $installedVersion)."
            }
        }
    }

    # Check if the module needs to be imported into the current session
    $importedModule = Get-Module -Name $ModuleName
    if ($null -eq $importedModule) {
        Write-Output "Module $ModuleName is not imported in the current session. Importing..."
        Import-Module -Name $ModuleName -Force
    } else {
        Write-Output "Module $ModuleName is already imported in the current session."
    }
}

function Ensure-PackageProvider {
    param (
        [string]$ProviderName,
        [string]$MinimumVersion
    )

    # Check if the package provider is installed
    $installedProvider = Get-PackageProvider -Name $ProviderName -ErrorAction SilentlyContinue

    if ($null -eq $installedProvider) {
        Write-Host "Package provider $ProviderName not found. Installing version $MinimumVersion or higher..."
        Install-PackageProvider -Name $ProviderName -MinimumVersion $MinimumVersion -Force -Confirm:$false
    } else {
        $installedVersion = $installedProvider.Version
        [version]$minimumRequiredVersion = [version]$MinimumVersion

        # Check if the installed version meets the minimum required version
        if ($installedVersion -lt $minimumRequiredVersion) {
            Write-Host "$ProviderName is installed, but version $installedVersion is less than the minimum required version $MinimumVersion."
            Write-Host "Updating $ProviderName to at least version $MinimumVersion..."
            Install-PackageProvider -Name $ProviderName -MinimumVersion $MinimumVersion -Force -Confirm:$false
        } else {
            Write-Host "$ProviderName is already installed and meets the minimum version requirement (version $installedVersion)."
        }
    }
}

# Check if the script is running in elevated mode (as Administrator)
If (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script requires elevated privileges (Run as Administrator)."
    exit
}

cls
Write-Host "STATUS:"
Write-Host " "
Write-Host "Script started at $(Get-Date)"

Stop-ZabbixAgentService -ServiceName $ServiceName

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Ensure-Module -ModuleName "PowerShellGet"
Ensure-Module -ModuleName "PackageManagement"
Ensure-Module -ModuleName "Microsoft.PowerShell.PSResourceGet"
Ensure-PackageProvider -ProviderName "NuGet" -MinimumVersion $nuGetProviderMinVersion

#Downloading the correct ZABBIX version for the system architecture
if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
#Downloading the correct ZABBIX version for the 64-bit architecture
Invoke-WebRequest -Uri "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/$version/zabbix_agent-$version-windows-amd64-openssl.msi"  -OutFile "$env:TEMP\ZabbixAgent-v$version.msi"
} else {
#Downloading the correct ZABBIX version for the 32-bit architecture
Invoke-WebRequest -Uri "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/$version/zabbix_agent-$version-windows-i386-openssl.msi" -OutFile "$env:TEMP\ZabbixAgent-v$version.msi"
}

#Download template of ZABBIX Configuration file
Invoke-WebRequest -Uri "https://github.com/RoBeDi/PowerShell/raw/refs/heads/master/Zabbix/Intune/template_zabbix_agentd.conf" -OutFile "$env:TEMP\template_zabbix_agentd.conf"

#Install the downloaded version of ZABBIX for the appropriate system architecture
Start-Process -FilePath "$env:TEMP\ZabbixAgent-v$version.msi" -ArgumentList "/qn SERVER=$ZabbixServer SERVERACTIVE=$ZabbixServerActive HOSTNAME=$env:computername ListenPort=$ListenPort EnablePath=$EnablePath" -Wait

############ UPDATE ZABBIX CONFIG FILE #################
Start-Sleep -Seconds 5
Write-Host "Reconfiguring Zabbix Agent " -NoNewline
Start-Sleep -Seconds 2
Write-Host "... " -NoNewline
Write-Host "DONE" -ForegroundColor Green

Get-ChildItem $AgentConfFile | Rename-Item -NewName {$_.BaseName + "_" + (Get-Date -F ddMMyyyy_HHmm) + $_.Extension}
Copy-Item -Path "$env:TEMP\template_zabbix_agentd.conf" -Destination $AgentConfFile -Force

Start-Sleep -Seconds 2
Write-Host "Writing variables into Zabbix Agent config file " -NoNewline

$ConfigContent = Get-Content $AgentConfFile
$ConfigContent | ForEach-Object {
	if($_ -eq "HostInterface="){
		$ConfigContent[$ConfigContent.IndexOf($_)] += $HostInterface
	}
    
    if($_ -eq "Hostname="){
		$ConfigContent[$ConfigContent.IndexOf($_)] += $env:COMPUTERNAME
	}
}

if ($HostInterface -like '10.145.*' -and $Model -eq '3') {
    $ConfigContent | ForEach-Object {
	    if($_ -eq "Server="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "[Zabbix_Proxy_Server_IP]"
	    }

        if($_ -eq "ServerActive="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "[Zabbix_Proxy_Server_IP]"
	    }

        if($_ -eq "HostMetaData="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "Windows servers"
	    }
    }
} elseif ($HostInterface -like '10.30.*' -and $Model -eq '3') {
    $ConfigContent | ForEach-Object {
	    if($_ -eq "Server="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "[Zabbix_Server_IP]"
	    }

        if($_ -eq "ServerActive="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "[Zabbix_Server_IP]"
	    }

        if($_ -eq "HostMetaData="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "Windows servers"
	    }
    }
} else {
    $ConfigContent | ForEach-Object {
	    if($_ -eq "Server="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "[Zabbix_Proxy_Server_IP]"
	    }

        if($_ -eq "ServerActive="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "[Zabbix_Proxy_Server_IP]"
	    }

        if($_ -eq "HostMetaData="){
		    $ConfigContent[$ConfigContent.IndexOf($_)] += "Windows clients"
	    }
    }
}

Set-Content $AgentConfFile -Value $ConfigContent

Start-Sleep -Seconds 2
Write-Host "... " -NoNewline
Write-Host "DONE" -ForegroundColor Green

############ Zabbix Agent Service #################
Start-Sleep -Seconds 10
Start-ZabbixAgentService -ServiceName $ServiceName
Write-Host "Upgrade of Zabbix Agent completed, the PowerShell window will close in 10 seconds..." -ForegroundColor Green
Start-Sleep 10 
Stop-Process -Id $PID