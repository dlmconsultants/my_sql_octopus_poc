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
Import-Module -Name "$PSScriptRoot\helper_functions.psm1" -Force

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_users.ps1"
Update-StatupStatus -status "1/4-CreatingLocalUsers"
Write-Output "Executing ./setup_users.ps1"
./setup_users.ps1

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_iis.ps1"
Update-StatupStatus -status "2/4-SettingUpIIS"
Write-Output "Executing ./setup_iis.ps1"
./setup_iis.ps1

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_dotnet_core.ps1"
Update-StatupStatus -status "3/4-SettingUpIIS"
Write-Output "Executing ./setup_dotnet_core.ps1"
./setup_dotnet_core.ps1

$octopusServerUrl = "__OCTOPUSURL__"
$registerInEnvironments = "__ENV__"
$registerInRoles = "__ROLE__"

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_tentacle.ps1"
Update-StatupStatus -status "4/4-SettingUpTentacle"
Write-Output "Executing ./install_tentacle.ps1 -octopusServerUrl $octopusServerUrl -registerInEnvironments $registerInEnvironments" -registerInRoles $registerInRoles
./install_tentacle.ps1 -octopusServerUrl $octopusServerUrl -registerInEnvironments $registerInEnvironments -registerInRoles $registerInRoles

Update-StatupStatus -status "Ready"

$date = Get-Date
Write-Output "VM_UserData startup script completed at $date."
</powershell>



