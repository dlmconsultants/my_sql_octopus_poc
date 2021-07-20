<powershell>
$ErrorActionPreference = "stop"

$startupDir = "C:\Startup"
$scriptsDir = "scripts"

if ((test-path $startupDir) -ne $true) {
  New-Item -ItemType "Directory" -Path $startupDir
}

Set-Location $startupDir

# If for whatever reason this doesn't work, check this file:
$log = ".\StartupLog.txt"
Write-Output " Creating log file at $log"
Start-Transcript -path $log -append

$date = Get-Date
Write-Output "VM_UserData startup script started at $date."

Set-Location $startupDir

if ((test-path $scriptsDir) -ne $true) {
  New-Item -ItemType "Directory" -Path $scriptsDir
}

Set-Location $scriptsDir

Function Get-Script{
  param (
    [Parameter(Mandatory=$true)][string]$script,
    [string]$owner = "__REPOOWNER__",
    [string]$repo = "__REPONAME__",
    [string]$branch = "main",
    [string]$path = "Infrastructure\UserDataDownloads"
  )
  # If the repo owner and name have not been replaced, pull scripts from origin repo
  if ($owner -like "*REPOOWNER*"){
    $owner = "dlmconsultants"
  }
  if ($repo -like "*REPONAME*"){
    $repo = "my_sql_octopus_poc"
  }
  # Download script
  $uri = "https://raw.githubusercontent.com/$owner/$repo/$branch/$path/$script"
  Write-Output "Downloading $script"
  Write-Output "  from: $uri"
  Write-Output "  to: .\$script"
  Invoke-WebRequest -Uri $uri -OutFile ".\$script" -Verbose
}

Get-Script -script "helper_functions.psm1"
Write-Output "Importing helper funtions"
Import-Module -Name "$startupDir\$scriptsDir\helper_functions.psm1" -Force

# Checking the secrets exist and (where applicable) are in the correct format
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "validate_secrets.ps1"
Update-StatupStatus -status "setup-1/5-validatingSecrets"
Write-Output "Executing ./validate_secrets.ps1 -octopusUrl __OCTOPUSURL__"
./validate_secrets.ps1 -octopusUrl __OCTOPUSURL__

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_users.ps1"
Write-Output "Executing ./setup_users.ps1"
Update-StatupStatus -status "setup-2/5-CreatingLocalUsers"
./setup_users.ps1

$octopusServerUrl = "__OCTOPUSURL__"
$registerInEnvironments = "__ENV__"
$registerInRoles = "__ROLE__"
$sqlServerIp = "__SQLSERVERIP__"

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_tentacle.ps1"
Update-StatupStatus -status "setup-3/5-InstallingTentacle"
Write-Output "Executing ./install_tentacle.ps1 -octopusServerUrl $octopusServerUrl -registerInEnvironments $registerInEnvironments" -registerInRoles $registerInRoles
./install_tentacle.ps1 -octopusServerUrl $octopusServerUrl -registerInEnvironments $registerInEnvironments -registerInRoles $registerInRoles

# Installing tentacle changes the location so switching it back
set-location "$startupDir\$scriptsDir"

# Creating SQL logins so that student and octopus can both access SQL Server
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_sql_server.ps1"
Update-StatupStatus -status "setup-4/5-SettingUpSqlServer"
Write-Output "Executing ./setup_sql_server.ps1 -tag $registerInRoles -value $registerInEnvironments -SQLServer $sqlServerIp"
./setup_sql_server.ps1 -tag $registerInRoles -value $registerInEnvironments -SQLServer $sqlServerIp

# Taking the opportunity to install a few useful PowerShell modules
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_jumpbox_ps_modules.ps1"
Update-StatupStatus -status "setup-5/5-InstallingJumpboxModules"
Write-Output "Executing ./install_jumpbox_ps_modules.ps1"
./install_jumpbox_ps_modules.ps1

# Installing SSMS for convenience (with Chocolatey). Not required to deploy anything so doing this last to avoid delays.
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_choco.ps1"
Update-StatupStatus -status "ready-convenience1/2-InstallingChoco"
Write-Output "Executing ./install_choco.ps1"
./install_choco.ps1

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_ssms.ps1"
Update-StatupStatus -status "ready-convenience2/2-InstallingSSMS"
Write-Output "Executing ./install_ssms.ps1"
./install_ssms.ps1

Update-StatupStatus -status "ready"

$date = Get-Date
Write-Output "VM_UserData startup script completed at $date."
</powershell>



