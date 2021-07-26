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
try {
  ./validate_secrets.ps1 -octopusUrl __OCTOPUSURL__
}
catch {
  $errorMessage = "FAILED: VMUserData script failed when trying to run: ./validate_secrets.ps1 -octopusUrl __OCTOPUSURL__. Last error code was: $Error[0]"
  Update-StatupStatus -status $errorMessage
  Write-Error $errorMessage
}

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_users.ps1"
Update-StatupStatus -status "setup-2/5-CreatingLocalUsers"
Write-Output "Executing ./setup_users.ps1"
try {
  ./setup_users.ps1
}
catch {
  $errorMessage = "FAILED: VMUserData script failed when trying to run: ./setup_users.ps1. Last error code was: $Error[0]"
  Update-StatupStatus -status $errorMessage
  Write-Error $errorMessage
}

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_iis.ps1"
Update-StatupStatus -status "setup-3/5-SettingUpIIS"
Write-Output "Executing ./setup_iis.ps1"
try {
  ./setup_iis.ps1
}
catch {
  $errorMessage = "FAILED: VMUserData script failed when trying to run: ./setup_iis.ps1. Last error code was: $Error[0]"
  Update-StatupStatus -status $errorMessage
  Write-Error $errorMessage
}

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_dotnet_core.ps1"
Update-StatupStatus -status "setup-4/5-SettingUpDotNetCore"
Write-Output "Executing ./setup_dotnet_core.ps1"
try {
  ./setup_dotnet_core.ps1
}
catch {
  Write-Output "*** $date ***"
  Write-Warning "First attempt to setup dotnet core failed: $Error[0]"
  Write-Output "Trying again" 
  Update-StatupStatus -status "setup-4/5-SettingUpDotNetCore-2ndTry"
  try {
    ./setup_dotnet_core.ps1
  }
  catch {
    Write-Output "*** $date ***"
    Write-Warning "Second attempt to setup dotnet core failed: $Error[0]"
    Write-Output "Trying again" 
    Update-StatupStatus -status "setup-4/5-SettingUpDotNetCore-3rdTry"
    try {
      ./setup_dotnet_core.ps1
    }
    catch {
      $errorMessage = "FAILED: VMUserData script failed 3 times when trying to run: ./setup_dotnet_core.ps1. Last error code was: $Error[0]"
      Update-StatupStatus -status $errorMessage
      Write-Error $errorMessage
    }
  }
}

$octopusServerUrl = "__OCTOPUSURL__"
$registerInEnvironments = "__ENV__"
$registerInRoles = "__ROLE__"

$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_tentacle.ps1"
Update-StatupStatus -status "setup-5/5-SettingUpTentacle"
Write-Output "Executing ./install_tentacle.ps1 -octopusServerUrl $octopusServerUrl -registerInEnvironments $registerInEnvironments" -registerInRoles $registerInRoles
try {
  ./install_tentacle.ps1 -octopusServerUrl $octopusServerUrl -registerInEnvironments $registerInEnvironments -registerInRoles $registerInRoles
}
catch {
  $errorMessage = "FAILED: VMUserData script failed when trying to run: ./install_tentacle.ps1 -octopusServerUrl $octopusServerUrl -registerInEnvironments $registerInEnvironments -registerInRoles $registerInRoles. Last error code was: $Error[0]"
  Update-StatupStatus -status $errorMessage
  Write-Error $errorMessage
}

Update-StatupStatus -status "ready"

$date = Get-Date
Write-Output "VM_UserData startup script completed at $date."
</powershell>



