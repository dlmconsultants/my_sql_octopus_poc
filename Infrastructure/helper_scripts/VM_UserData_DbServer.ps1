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
    $owner = "my_sql_octopus_poc"
  }
  # Download script
  $uri = "https://raw.githubusercontent.com/$owner/$repo/$branch/$path/$script"
  Write-Output "Downloading $script"
  Write-Output "  from: $uri"
  Write-Output "  to: .\$script"
  Invoke-WebRequest -Uri $uri -OutFile ".\$script" -Verbose
}

# Setting up users first, so that if anything goes wrong later, folks can RDP in to troubleshoot
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "setup_users.ps1"
Write-Output "Executing ./setup_users.ps1"
./setup_users.ps1

# Chocolatey is required for both SQL Server and SSMS installs
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_choco.ps1"
Write-Output "Executing ./install_choco.ps1"
./install_choco.ps1

# Installing SQL Server, using a specific config file
$date = Get-Date
Write-Output "*** $date ***"
Write-Output "Downloading ConfigurationFile.ini and install_sql_with_choco.ps1"
Get-Script -script "ConfigurationFile.ini"
Get-Script -script "install_sql_server.ps1"
Write-Output "Executing ./install_sql_server.ps1"
./install_sql_server.ps1

# Installing SSMS for convenience. Not required to deploy anything so doing this last to avoid delays.
$date = Get-Date
Write-Output "*** $date ***"
Get-Script -script "install_ssms.ps1"
Write-Output "Executing ./install_ssms.ps1"
./install_ssms.ps1

$date = Get-Date
Write-Output "VM_UserData startup script completed at $date."
</powershell>



