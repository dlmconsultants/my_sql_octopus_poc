param(
    $tag = "", 
    $value = "",
    [Parameter(Mandatory=$true)]$SQLServer = ""
)

# Installing dbatools
Write-Output "      Installing NuGet package provider (required for dbatools)..."
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force 
Write-Output "      Installing dbatools PowerShell module..."
Install-Module dbatools -Force

# Function to securely retrieve secrets from AWS Secrets Manager
function get-secret(){
  param ($secret)
  $secretValue = Get-SECSecretValue -SecretId $secret
  # values are returned in format: {"key":"value"}
  $splitValue = $secretValue.SecretString -Split '"'
  $cleanedSecret = $splitValue[3]
  return $cleanedSecret
}

Write-Output "  Getting sql passwords from AWS Secrets Manager"
$studentPassword = Get-Secret -secret "STUDENT_SQL_PASSWORD" | ConvertTo-SecureString -AsPlainText -Force
$octopusPassword = Get-Secret -secret "OCTOPUS_SQL_PASSWORD" | ConvertTo-SecureString -AsPlainText -Force
$saPassword = Get-Secret -secret "SYSADMIN_SQL_PASSWORD" | ConvertTo-SecureString -AsPlainText -Force

$saUser = "sa"
$cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $saUser, $saPassword

import-module dbatools

# Waiting for SQL Server to come online
$sqlOnline = $false
$stopwatch =  [system.diagnostics.stopwatch]::StartNew()
while ($sqlOnline -like $false){
  $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
  try { 
    Invoke-DbaQuery -SqlInstance $SQLServer -Query 'SELECT @@version' -SqlCredential $cred -EnableException -QueryTimeout 1
    Write-Output "    SQL Server is responding."
    $sqlOnline = $true
  }
  catch {
    Write-output $Error[0]
    Write-Output "        $time seconds: Waiting for SQL Server to come online..."
  }
  if ($time -gt 1200){
    Write-Error "$time seconds: SQL Server is taking too long to come online. Something is wrong."
  }
  Start-Sleep -s 5
}

Write-Output "  Creating student and octopus logins."
New-DbaLogin -SqlInstance $SQLServer -Login student -SecurePassword $studentPassword -SqlCredential $cred
New-DbaLogin -SqlInstance $SQLServer -Login octopus -SecurePassword $octopusPassword -SqlCredential $cred

Write-Output "  Making both student and octopus logins SysAdmins."
Set-DbaLogin -SqlInstance $SQLServer -Login student -AddRole "sysadmin" -SqlCredential $cred
Set-DbaLogin -SqlInstance $SQLServer -Login octopus -AddRole "sysadmin" -SqlCredential $cred

Write-Output "  Creating databases."
New-DbaDatabase -SqlInstance $SQLServer -Name AdventureWorks, SqlServerCentral, WideWorldImporters, RandomQuotes -SqlCredential $cred
