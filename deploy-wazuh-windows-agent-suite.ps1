#
# deploy-wazuh-windows-agent-suite.ps1
# by Kevin Branch (kevin@branchnetconsulting.com)
# with contributions by Ken Fredericksen (ken@branchnetconsulting.com)
#
# Deployment script for Wazuh agent and subagents (by default Sysmon and Osquery).  
#
# The Agent self registration process is included, but will be skipped if an existing working registration can be recycled.
#
# From command shell or PowerShell (Run as Administrator), run this script as follows:
# 	PowerShell.exe -ExecutionPolicy Bypass -File ./deploy-wazuh-windows-agent-suite.ps1 -WazuhMgr "10.20.30.40" -WazuhRegPass "theRegistrationPW"
#
# This script should work on Windows systems as old as Windows Server 2012 provided PowerShell 5.1 is present.  Likely Powershell 5.0 would be OK.
#
# No provision has been made for Sysmon to work on Windows systems that have no 32-bit subsystem present (like Windows Nano and possible Core).  
# They would need Sysmon64.exe run instead of Sysmon.exe.  A little logic to detect a 64 bit Windows system with no 32 bit subsystem would not
# be that difficult to add.  
#
# This also installs a custom active-response script to be directly invoked via the Wazuh API against all agents using Sysmon 
# to cause Sysmon.exe on each agent to import and apply the latest version of C:\Program Files (x86)\ossec-agent\shared\sysmonconfig.xml.
# Sections like below are presumed to be in ossec.conf on the Wazuh manager(s).  The script reload-sysmon.cmd must also be on the managers.
#
#  <command>
#    <name>reload-sysmon</name>
#    <executable>reload-sysmon.cmd</executable>
#    <expect/>
#    <timeout_allowed>no</timeout_allowed>
#  </command>
#
#  <active-response>
#    <disabled>no</disabled>
#    <command>reload-sysmon</command>
#    <location>local</location>
#    <!-- This AR is only to be invoked via a direct Wazuh API call.  Group below does not exist. -->
#    <rules_group>run-directly-via-wazuh-api</rules_group>
#  </active-response>
#
#  To manually invoke the reload-sysmon AR, you can run this on all Wazuh managers to which agents are connected:
#    /var/ossec/bin/agent_control -b 1.1.1.1 -f reload-sysmon0 -a
#
# Last updated by Kevin Branch 5/13/2020.
#

#
# $WazuhVer			Full version of Wazuh agent to install, like "3.12.2"
# $WazuhMgr			IP or FQDN of the Wazuh manager for ongoing agent connections.  Required.
# $WazuhRegMgr		IP or FQDN of the Wazuh manager for agent registration connection (defaults to $WazuhMgr if not specified)
# $WazuhRegPass		Password for registration with Wazuh manager (put in quotes).  Required.
# $WazuhAgentName	Name under which to register this agent in place of locally detected Windows host name
# $WazuhGroups		Comma separated list of Wazuh groups to member this agent.  No spaces.  Put whole list in quotes.  Groups must already exist.
# $WazuhSrc			Static download path to fetch Wazuh agent installer.  Overrides $WazVer
# $SysmonSrc		Static download path to fetch Sysmon installer zip file.  
# $SysmonConfSrc	Static download path to fetch Sysmon configuration file.
# $SkipSysmon		Do not install Sysmon.  Completely remove it if present.
# $OsqueryVer		Full version of Osquery to install, like "4.2.0"
# $OsquerySrc		Static download path to fetch Osquery agent installer.  Overrides $OsqVer
# $SkipOsquery		Do not install Osquery.  Completely remove it if present.
# $Local			Expect all download files already to be present in current directory.  Do not use any $...Src parameters with this.
#
param ( $WazuhVer = "3.13.1", 
	$WazuhMgr, 
	$WazuhRegMgr, 
	$WazuhRegPass, 
	$WazuhAgentName = $env:computername, 
	$WazuhGroups, 
	$WazuhSrc, 
	$SysmonSrc = "https://download.sysinternals.com/files/Sysmon.zip", 
	$SysmonConfSrc = "https://raw.githubusercontent.com/branchnetconsulting/sysmon-config/master/sysmonconfig-export.xml", 
	[switch]$SkipSysmon=$false, 
	$OsqueryVer = "4.4.0", 
	$OsquerySrc, 
	[switch]$SkipOsquery=$false,
	[switch]$Local=$false
);

if ($WazuhMgr -eq $null) { 
	write-host "Must use '-WazuhMgr' to specify the FQDN or IP of the Wazuh manager to which the agent shall retain a connection."
	exit 1
}
if ($WazuhRegPass -eq $null) { 
	write-host "Must use '-WazuhRegPass' to specify the password to use for agent registration."
	exit 1
}
if ($WazuhRegMgr -eq $null) { 
    $WazuhRegMgr = $WazuhMgr
}
if ($WazuhSrc -eq $null) { 
    $WazuhSrc = "https://packages.wazuh.com/3.x/windows/wazuh-agent-$WazuhVer-1.msi"
}
if ($OsquerySrc -eq $null) { 
    $OsquerySrc = "https://pkg.osquery.io/windows/osquery-$OsqueryVer.msi"
}
if ( !($PSVersionTable.PSVersion.Major) -ge 5 ) {
	write-host "PowerShell 5.0 or higher is required by this script."
	exit 1
}

# Blend standard/dynamic groups with custom groups
$WazuhGroupsPrefix = "windows,"
if ( $SkipOsquery -eq $false ) {
	$WazuhGroupsPrefix = $WazuhGroupsPrefix+"osquery,"
}
if ( $SkipSysmon -eq $false ) {
	$WazuhGroupsPrefix = $WazuhGroupsPrefix+"sysmon,"
}
$WazuhGroups = $WazuhGroupsPrefix+$WazuhGroups
$WazuhGroups = $WazuhGroups.TrimEnd(",")

# If "-Local" option selected, confirm all required local files are present.
if ( $Local -eq $true ) {
	if ( -not (Test-Path -LiteralPath "nuget.zip") ) {
		Write-Output "Option '-Local' specified but no 'nuget.zip' file was found in current directory.  Giving up and aborting the installation..."
		exit 1
	}
	if ( -not (Test-Path -LiteralPath "wazuh-agent.msi") ) {
		Write-Output "Option '-Local' specified but no 'wazuh-agent.msi' file was found in current directory.  Giving up and aborting the installation..."
		exit 1
	}
	if ( -not (Test-Path -LiteralPath "Sysmon.zip") ) {
		Write-Output "Option '-Local' specified but no 'Sysmon.zip' file was found in current directory.  Giving up and aborting the installation..."
		exit 1
	}	
	if ( -not (Test-Path -LiteralPath "sysmonconfig.xml") ) {
		Write-Output "Option '-Local' specified but no 'sysmonconfig.xml' file was found in current directory.  Giving up and aborting the installation..."
		exit 1
	}	
	if ( -not (Test-Path -LiteralPath "osquery.msi") ) {
		Write-Output "Option '-Local' specified but no 'osquery.msi' file was found in current directory.  Giving up and aborting the installation..."
		exit 1
	}
}

# Set https protocol defaults to try stronger TLS first and allow all three forms of TLS
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

# Take note if agent is already connected to a Wazuh manager and collect relevant data
# If the agent is already connected to the same target manager, the agent name has not changed, and the agent group list is exactly the same,
# then the registration will be retained by backing up client.keys now and restoring it after reinstallation of the Wazuh agent, skipping self-registration. 
$file = Get-Content "C:\Program Files (x86)\ossec-agent\ossec-agent.state" -erroraction 'silentlycontinue'
$file2 = Get-Content "C:\Program Files (x86)\ossec-agent\shared\merged.mg" -erroraction 'silentlycontinue'
if ($file -match "'connected'" ) {
    echo "Agent currently connected, so saving client.keys to $env:TEMP\client.keys.bnc"
    $ALREADY_CONNECTED="yes"
    $OLDNAME=(type "C:\Program Files (x86)\ossec-agent\client.keys").Split(" ")[1]
    Remove-Item -Path "$env:TEMP\client.keys.bnc" -erroraction 'silentlycontinue' | out-null
    Copy-Item 'C:\Program Files (x86)\ossec-agent\client.keys' -Destination "$env:TEMP\client.keys.bnc"
    if ($file2 -match "Source\sfile:") {
        $CURR_GROUPS=((((Select-String -Path 'C:\Program Files (x86)\ossec-agent\shared\merged.mg' -Pattern "Source file:") | Select-Object -ExpandProperty Line).Replace("<!-- Source file: ","")).Replace("/agent.conf -->","")) -join ','
    } else {
        # If the agent is presently a member of only one agent group, then pull that group name into current group variable.
        $CURR_GROUPS=((((Select-String -Path 'C:\Program Files (x86)\ossec-agent\shared\merged.mg' -Pattern "#") | Select-Object -ExpandProperty Line).Replace("#","")))
    }
} 

# NuGet Dependency

if ( -not (Test-Path -LiteralPath "C:\Program Files\PackageManagement\ProviderAssemblies\nuget" -PathType Container) ) {
	echo "Installing dependency (NuGet) to be able to uninstall other packages..."
	if ( $Local -eq $false ) {
		cd c:\
		$count = 0
		$success = $false;
		do{
			try{
				Install-PackageProvider -Name NuGet -Force
				$success = $true
			}
			catch{
				if ($count -lt 5) {
					Write-Output "Download attempt failed.  Will retry 10 seconds."
				} else {
					Write-Output "Download attempt still failed.  Giving up and aborting the installation..."
					exit 1
				}
				Start-sleep -Seconds 10
			}  
			$count++    
		}until($count -eq 6 -or $success)
	} else {
		if ( -not (Test-Path -LiteralPath "C:\Program Files\PackageManagement\ProviderAssemblies" -PathType Container ) ) {
			New-Item -ItemType "directory" -Path "C:\Program Files\PackageManagement\ProviderAssemblies"
		}
		Expand-Archive "nuget.zip" -DestinationPath "C:\Program Files\PackageManagement\ProviderAssemblies\"
		Import-PackageProvider -Name NuGet
	}
}

#
# Wazuh Agent 
#

# Download Wazuh Agent installer or confirm it is already locally present if "-Local" option specified.
if ( $Local -eq $false ) {
	# Download the correct version of the Wazuh installer MSI
	echo "Downloading $WazuhSrc"
	$count = 0
	$success = $false;
	do{
		try{
			Invoke-WebRequest -Uri $WazuhSrc -OutFile wazuh-agent.msi
			$success = $true
		}
		catch{
			if ($count -lt 5) {
				Write-Output "Download attempt failed.  Will retry 10 seconds."
			} else {
				Write-Output "Download attempt still failed.  Giving up and aborting the installation..."
				exit 1
			}
			Start-sleep -Seconds 10
		}  
		$count++    
	}until($count -eq 6 -or $success)
}


# If Wazuh agent already installed, blow it away
echo "Stopping old Wazuh Agent if present"
net stop wazuh
echo "Uninstalling old Wazuh Agent if present"
Uninstall-Package -Name "Wazuh Agent" -erroraction 'silentlycontinue' | out-null

# Install Wazuh Agent and then remove the installer file
echo "Installing Wazuh Agent"
Start-Process -FilePath wazuh-agent.msi -ArgumentList "/q" -Wait -WindowStyle 'Hidden'
if ( $Local -eq $false ) {
	rm .\wazuh-agent.msi
}

# If we can safely skip self registration and just restore the backed up client.keys file, then do so. Otherwise, self-register.
# This should keep us from burning through so many agent ID numbers.
$SKIP_REG = "no"
if ($ALREADY_CONNECTED -eq "yes") { 
	echo "Agent is presently connected..."
	echo "Current registered agent name is: $OLDNAME and new target name is: $WazuhAgentName"
	if ($WazuhAgentName -eq $OLDNAME) {
		echo "Old and new agent registration names match." 
                echo "Current group memberships are: $CURR_GROUPS and new target group memberships are: $WazuhGroups"
		if ($CURR_GROUPS -eq $WazuhGroups) {
			echo "Old and new agent group memberships match. Will skip self-registration and restore client.keys backup instead."
			$SKIP_REG = "yes"
		}
	}
} else {
   echo "Current groups and new target groups do not match."
   $SKIP_REG = "no"
}

if  ($SKIP_REG -eq "no") {
    # Register the agent with the manager
    echo "Registering Wazuh Agent with $WazuhRegMgr..."
    C:\Progra~2\ossec-agent\agent-auth.exe -m "$WazuhRegMgr" -P "$WazuhRegPass" -G "$WazuhGroups" -A "$WazuhAgentName"
} else {
	Copy-Item "$env:TEMP\client.keys.bnc" -Destination 'C:\Program Files (x86)\ossec-agent\client.keys'
}

# Detect Windows version for use in configprofile line of ossec.conf
switch ((Get-CimInstance Win32_OperatingSystem).BuildNumber) 
{
    6001 {$OS = "Win2008"}
    6002 {$OS = "Win2008"}
    6003 {$OS = "Win2008"}
    7600 {$OS = "Win2008, Win2008R2"}
    7601 {$OS = "Win2008, Win2008R2"}    
    9200 {$OS = "Win2012"}
    9600 {$OS = "Win2012, Win2012R2"}
    14393 {$OS = "Win2016"}
    16299 {$OS = "Win2016"}
    10240 {$OS = "Win10or2019"}
    10586 {$OS = "Win10or2019"}
    14393 {$OS = "Win10or2019"}
    15063 {$OS = "Win10or2019"}
    16299 {$OS = "Win10or2019"}
    17134 {$OS = "Win10or2019"}
    17763 {$OS = "Win10or2019"}
    18362 {$OS = "Win10or2019"}
    18363 {$OS = "Win10or2019"}
	{$_ -gt 18362} {$OS = "Win10or2019"}
    default { $OS = "WindowsUnknown"}
}

echo "Writing ossec.conf"
# Write the ossec.conf file
$ConfigToWrite = @"
<ossec_config>
   <client>
      <server>
         <address>$WazuhMgr</address>
         <port>1514</port>
         <protocol>tcp</protocol>
      </server>
      <config-profile>$OS</config-profile>
      <notify_time>60</notify_time>
      <time-reconnect>300</time-reconnect>
      <auto_restart>yes</auto_restart>
   </client>
   <logging>
      <log_format>plain,json</log_format>
   </logging>
</ossec_config>
"@
$ConfigToWrite | Out-File -FilePath C:/Progra~2/ossec-agent/ossec.conf -Encoding ASCII

# Write the local_internal_options.conf file
echo "Writing local_internal_options.conf..."
$ConfigToWrite = @"
logcollector.remote_commands=1
wazuh_command.remote_commands=1
sca.remote_commands=1
"@
$ConfigToWrite | Out-File -FilePath C:/Progra~2/ossec-agent/local_internal_options.conf -Encoding ASCII

#
# Sysmon
#

# Create "C:\Program Files (x86)\sysmon-wazuh" directory if missing
if ( -not (Test-Path -LiteralPath "C:\Program Files (x86)\sysmon-wazuh" -PathType Container) ) { New-Item -Path "C:\Program Files (x86)\" -Name "sysmon-wazuh" -ItemType "directory" | out-null }


# Download and unzip Sysmon.zip, or unzip it from local directory if "-Local" option specified.
# Sysmon must be acquired locally or via download even if "-SkipSysmon" was specified, so that we can use Sysmon.exe to uninstall Sysmon.
Remove-Item "C:\Progra~2\sysmon-wazuh\*" -Force
if ( $Local -eq $false ) {
	echo "Downloading and unzipping Sysmon installer..."
	$count = 0
	$success = $false;
	do{
		try{
			Invoke-WebRequest -Uri $SysmonSrc -OutFile "$env:TEMP\Sysmon.zip"
			$success = $true
		}
		catch{
			if ($count -lt 5) {
				Write-Output "Download attempt failed.  Will retry 10 seconds."
			} else {
				Write-Output "Download attempt still failed.  Giving up and aborting the installation..."
				exit 1
			}
			Start-sleep -Seconds 10
		}  
		$count++    
	}until($count -eq 6 -or $success)
	Expand-Archive "$env:TEMP\Sysmon.zip" -DestinationPath "C:\Program Files (x86)\sysmon-wazuh"
	Remove-Item "$env:TEMP\Sysmon.zip" -Force
} else {
	Expand-Archive "Sysmon.zip" -DestinationPath "C:\Program Files (x86)\sysmon-wazuh\"
}

if ( $SkipSysmon -eq $false ) {
	# Download SwiftOnSecurity config file for Sysmon or confirm it is already locally present if "-Local" option specified.
	if ( $Local -eq $false ) {
		# Download the latest SwiftOnSecurity config file for Sysmon and write it to Wazuh agent shared directory.
		# This is only to seed it so that the install process works even if the official and perhaps localized file hasn't propagated down from Wazuh manager yet.
		echo "Downloading $SysmonConfSrc as sysmonconfig.xml..."
		$count = 0
		$success = $false;
		do{
			try{
				Invoke-WebRequest -Uri "$SysmonConfSrc" -OutFile "C:\Program Files (x86)\ossec-agent\shared\sysmonconfig.xml"
				$success = $true
			}
			catch{
				Write-Output "Next attempt in 10 seconds"
				Start-sleep -Seconds 10
			}  
			$count++    
		}until($count -eq 6 -or $success)
		if(-not($success)){exit 1}
	} else {	
		Copy-Item "sysmonconfig.xml" -Destination "C:\Program Files (x86)\ossec-agent\shared\"
	}
}

echo "Removing Sysmon if present..."
Start-Process -FilePath C:\Progra~2\sysmon-wazuh\Sysmon.exe -ArgumentList "-u" -Wait -WindowStyle 'Hidden'

if ( $SkipSysmon -eq $false ) {
echo "Installing Sysmon..."
Start-Process -FilePath C:\Progra~2\sysmon-wazuh\Sysmon.exe -ArgumentList "-i","c:\progra~2\ossec-agent\shared\sysmonconfig.xml","-accepteula" -Wait -WindowStyle 'Hidden'

# Write the active-response script reload-sysmon.cmd to the Wazuh AR directory so that it can be run when new Sysmon configs arrive to import them.
echo "Writing reload-sysmon.cmd..."
$ScriptToWrite = @"
@ECHO OFF
FOR /F "TOKENS=1* DELIMS= " %%A IN ('DATE/T') DO SET DATE=%%B
FOR /F "TOKENS=1* DELIMS= " %%A IN ('TIME/T') DO SET TIME=%%A
ECHO %DATE% %TIME% %0 %1 %2 %3 %4 %5 %6 %7 %8 %9 >> C:\Progra~2\ossec-agent\active-response\active-responses.log
c:\progra~2\sysmon-wazuh\Sysmon.exe -c c:\progra~2\ossec-agent\shared\sysmonconfig.xml
"@
$ScriptToWrite | Out-File -FilePath C:\Progra~2\ossec-agent\active-response\bin\reload-sysmon.cmd -Encoding ASCII
}

if ( $SkipSysmon -eq $true ) {
	Remove-Item "C:\Program Files (x86)\sysmon-wazuh" -recurse -erroraction 'silentlycontinue'
}

#
# osquery
#

# Remove osquery if present (making sure wazuh agent is not running before blowing away osquery dir)
echo "Removing Osquery if present..."
net stop wazuh
Uninstall-Package -Name "osquery" -erroraction 'silentlycontinue' | out-null
Remove-Item "C:\Progra~1\osquery" -recurse -erroraction 'silentlycontinue'

if ( $SkipOsquery -eq $false ) {
	# Download Osquery installer or confirm it is already locally present if "-Local" option specified.
	if ( $Local -eq $false ) {
		# Download the osquery MSI
		echo "Downloading $OsquerySrc..."
		$count = 0
		$success = $false;
		do{
			try{
				Invoke-WebRequest -Uri $OsquerySrc -OutFile osquery.msi
				$success = $true
			}
			catch{
				if ($count -lt 5) {
					Write-Output "Download attempt failed.  Will retry 10 seconds."
				} else {
					Write-Output "Download attempt still failed.  Giving up and aborting the installation..."
					exit 1
				}
				Start-sleep -Seconds 10
			}  
			$count++    
		}until($count -eq 6 -or $success)
	} 	

	# Install osquery
	Start-Process -FilePath osquery.msi -ArgumentList "/q" -Wait -WindowStyle 'Hidden'
	if ( $Local -eq $false ) {
		rm .\osquery.msi
	}
	# Remove the Windows service that the MSI installed which we do not want
	echo "Removing the osquery Windows service so Wazuh agent can manage it instead..."
	Start-Process -FilePath C:\Progra~1\osquery\osqueryd\osqueryd.exe -ArgumentList "--uninstall" -Wait -WindowStyle 'Hidden'
}

#
# Last Wazuh Agent steps
#

# Start up the Wazuh agent service
echo "Starting up the Wazuh agent..."
net start wazuh

# After 15 seconds confirm agent connected to manager
echo "Pausing for 15 seconds to allow agent to connect to manager..."
Start-Sleep -s 15 
$file = Get-Content "C:\Program Files (x86)\ossec-agent\ossec.log" -erroraction 'silentlycontinue'
if ($file -match "Connected to the server " ) {
	echo "This agent has successfully connected to the Wazuh manager!"
	exit 0
} else {
	echo "This agent FAILED to connect to the Wazuh manager."
	exit 1
}
