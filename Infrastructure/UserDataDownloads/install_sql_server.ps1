# updating the sa user
Write-Host "Getting the name of the current user to replace in the copy ini file."
$user = "$env:UserDomain\$env:USERNAME"
write-host $user

Write-Host "Replacing the placeholder user name in Confifuration.ini with $user."
$replaceText = (Get-Content -path "C:\Startup\scripts\ConfigurationFile.ini" -Raw) -replace "__MY_USER__", $user
Set-Content "C:\Startup\scripts\ConfigurationFile.ini" $replaceText

Write-Host "Retrieving sa password from EC2 Secrets Manager and updating Confifuration.ini."
$saPassword = Get-Secret -secret "SYSADMIN_SQL_PASSWORD"
$replaceText = (Get-Content -path "C:\Startup\scripts\ConfigurationFile.ini" -Raw) -replace "__SQL_SA_PASSWORD__", $saPassword
Set-Content "C:\Startup\scripts\ConfigurationFile.ini" $replaceText

# updating firewall
Write-Host "Opening port 1433 on Windows Firewall"
& netsh.exe firewall add portopening TCP 1433 "SQL Server"
if ($lastExitCode -ne 0) {
  throw "Installation failed when modifying firewall rules"
}

# installing SQL Server
Write-Host "Installing SQL Server with Chocolatey."
choco install sql-server-2019 --params="'/ConfigurationFile:C:\Startup\scripts\ConfigurationFile.ini'"
