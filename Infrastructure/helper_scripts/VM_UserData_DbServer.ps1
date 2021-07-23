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

# Setting up users first, so that if anything goes wrong later, folks can RDP in to troubleshoot
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_users.ps1"
Update-StatupStatus -status "setup-2/4-CreatingLocalUsers"
Write-Output "Executing ./setup_users.ps1"
try {
  ./setup_users.ps1
}
catch {
  $errorMessage = "FAILED: VMUserData script failed when trying to run: ./setup_users.ps1. Last error code was: $Error[0]"
  Update-StatupStatus -status $errorMessage
  Write-Error $errorMessage
}

# Chocolatey is required for both SQL Server and SSMS installs
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_choco.ps1"
Update-StatupStatus -status "setup-3/4-InstallingChoco"
Write-Output "Executing ./install_choco.ps1"
try {
  ./install_choco.ps1
}
catch {
  $errorMessage = "FAILED: VMUserData script failed when trying to run: ./install_choco.ps1. Last error code was: $Error[0]"
  Update-StatupStatus -status $errorMessage
  Write-Error $errorMessage
}


# Installing SQL Server, using a specific config file
$date = Get-Date
Write-Output "*** $date ***"
Write-Output "Downloading ConfigurationFile.ini and install_sql_with_choco.ps1"
Get-Script -script "ConfigurationFile.ini"
Get-Script -script "install_sql_server.ps1"
Update-StatupStatus -status "setup-4/4-InstallingSqlServer"
Write-Output "Executing ./install_sql_server.ps1"
try {
  ./install_sql_server.ps1
}
catch {
  $errorMessage = "FAILED: VMUserData script failed when trying to run: ./install_sql_server.ps1. Last error code was: $Error[0]"
  Update-StatupStatus -status $errorMessage
  Write-Error $errorMessage
}

# Installing SSMS for convenience. Not required to deploy anything so doing this last to avoid delays.
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_ssms.ps1"
Update-StatupStatus -status "ready-convenience1/1-InstallingSSMS"
Write-Output "Executing ./install_ssms.ps1"
try {
  ./install_ssms.ps1
}
catch {
  $errorMessage = "FAILED: VMUserData script failed when trying to run: ./install_ssms.ps1. Last error code was: $Error[0]"
  Update-StatupStatus -status $errorMessage
  Write-Error $errorMessage
}

Update-StatupStatus -status "ready"

$date = Get-Date
Write-Output "VM_UserData startup script completed at $date."
</powershell>



