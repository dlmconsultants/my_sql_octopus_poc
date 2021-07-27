<#
    Script to spin up all the required infrastructure.
    Script has 7 parts:
    1. Initialising variables etc
    2. Determine how many machines need to be added/deleted
    3. Removing everything that needs to be deleted
    4. Adding anything that needs to be added
    5. Installing dbatools so that we cna ping SQL Server to see when it comes online
    6. Waiting until everything comes back online
    7. Verify that we have the correct number of machines
#>

param(
    $instanceType = "t2.micro", # 1 vCPU, 1GiB Mem, free tier elligible: https://aws.amazon.com/ec2/instance-types/
    $numWebServers = 1,
    $timeout = 1800, # 30 minutes, in seconds
    $octoApiKey = "",
    $octopusSqlPassword = "",
    $octoUrl = "",
    $environment = ""
)

##########     1. Initialising variables etc     ##########

# Importing helper functions
Import-Module -Name "$PSScriptRoot\helper_functions.psm1" -Force

# If anything fails, stop
$ErrorActionPreference = "Stop"

# Starting a stopwatch so we can accurately log timings
$stopwatch =  [system.diagnostics.stopwatch]::StartNew()

# Initialising variables
# Getting the required instance ami for AWS region
$image = Get-SSMLatestEC2Image -ImageName Windows_Server-2019-English-Full-Bas* -Path ami-windows-latest | Where-Object {$_.Name -like "Windows_Server-2019-English-Full-Base"} | Select-Object Value
$ami = $image.Value
Write-Output "    Windows_Server-2019-English-Full-Base image in this AWS region has ami: $ami"

Write-Output "    Auto-filling missing parameters from Octopus System Variables..."

# Role prefix
$rolePrefix = ""
try {
    $rolePrefix = $OctopusParameters["Octopus.Project.Name"]
    Write-Output "      Detected Octopus Project: $rolePrefix"
}
catch {
    $rolePrefix = "my_sql_octopus_poc"
}

# Environment Name
if ($environment -like ""){
    try {
        $environment = $OctopusParameters["Octopus.Environment.Name"]
        Write-Output "      Detected Octopus Environment Name: $environment"
    }
    catch {
        Write-Warning "No value provided for environment. Setting it to: $environment"
    }
}

# Octopus URL
if ($octoUrl -like ""){
    try {
        $octoUrl = $OctopusParameters["Octopus.Web.ServerUri"]
        Write-Output "      Detected Octopus URL: $octoUrl"
    }
    catch {
        Write-Error "Please provide a value for -octoUrl"
    }
}

# Octopus API Key
if ($octoApiKey -like ""){
    try {
        $octoApiKey = $OctopusParameters["OCTOPUS_APIKEY"]
    }
    catch {
        Write-Error "Please provide a value for -octoApiKey"
    }
}

# Octopus SQL Server Password
if ($octopusSqlPassword -like ""){
    try {
        [SecureString]$octopusSqlPassword = $OctopusParameters["OCTOPUS_SQL_PASSWORD"] | ConvertTo-SecureString -AsPlainText -Force
    }
    catch {
        Write-Warning "No octopus password provided for SQL Server. Skipping check to see if/when SQL Server comes online"
        [SecureString]$octopusSqlPassword = "The wrong password!" | ConvertTo-SecureString -AsPlainText -Force # Need to convert to secure string to avoid errors
    }
}
else {
    [SecureString]$octopusSqlPassword = $octopusSqlPassword | ConvertTo-SecureString -AsPlainText -Force # The param should really have been a SecureString to begin with...
}

# Infering the roles
$webServerRole = "$rolePrefix-WebServer"
$dbServerRole = "$rolePrefix-DbServer"
$dbJumpboxRole = "$rolePrefix-DbJumpbox"

# Reading and encoding the VM startup scripts
$webServerUserData = Get-UserData -fileName "VM_UserData_WebServer.ps1" -octoUrl $octoUrl -role $webServerRole -environment $environment -octopusSqlPassword $octopusSqlPassword
$dbServerUserData = Get-UserData -fileName "VM_UserData_DbServer.ps1" -octoUrl $octoUrl -role $dbServerRole -environment $environment -octopusSqlPassword $octopusSqlPassword

# Creating a datatable object to keep track of the status of all our instances
$instances = New-Object System.Data.Datatable
[void]$instances.Columns.Add("id")
[void]$instances.Columns.Add("state")
[void]$instances.Columns.Add("public_ip")
[void]$instances.Columns.Add("role")
[void]$instances.Columns.Add("status")

function Get-InstancesString (){
    $instancesString = "INSTANCES:"
    ForEach ($instance in $instances){
        $id = $instance.id
        $role = $instance.role
        $state = $instance.state
        $ip = $instance.public_ip
        $status = $instance.status
        $instancesString = @"
$instancesString
id: $id / role: $role / state: $state / ip: $ip / status: $status
"@
    }
    return $instancesString
}

##########     2. Determine what we already have     ##########

Write-Output "    Checking what infra we already have..."

$existingSqlInstances = Get-Servers -role "$rolePrefix-DbServer" -environment $environment -$includePending
$existingJumpInstances = Get-Servers -role "$rolePrefix-DbJumpbox" -environment $environment -$includePending
$existingWebInstances = Get-Servers -role "$rolePrefix-WebServer" -environment $environment -$includePending

ForEach ($instance in $existingSqlInstances){
    $id = $instance.InstanceId
    $state = $instance.state.name.value 
    $public_ip = $instance.PublicIpAddress
    $role = "Web Server"
    $status = (Get-EC2Tag -Filter @{Name="resource-id";Values=$id},@{Name="key";Values="StartupStatus"}).Value
    [void]$instances.Rows.Add($id,$state,$public_ip,"SQL Server",$status)
}
ForEach ($instance in $existingJumpInstances){
    $id = $instance.InstanceId
    $state = $instance.state.name.value 
    $public_ip = $instance.PublicIpAddress
    $role = "Web Server"
    $status = (Get-EC2Tag -Filter @{Name="resource-id";Values=$id},@{Name="key";Values="StartupStatus"}).Value
    [void]$instances.Rows.Add($id,$state,$public_ip,"DB Jumpbox",$status)
}
ForEach ($instance in $existingWebInstances){
    $id = $instance.InstanceId
    $state = $instance.state.name.value 
    $public_ip = $instance.PublicIpAddress
    $role = "Web Server"
    $status = (Get-EC2Tag -Filter @{Name="resource-id";Values=$id},@{Name="key";Values="StartupStatus"}).Value
    [void]$instances.Rows.Add($id,$state,$public_ip,"Web Server",$status)
}

$instancesString = Get-InstancesString
Write-output $instancesString

Write-Output "    Checking required infrastucture changes..."

$jumpboxExists = $false
if ("DB Jumpbox" -in $instances.role){
    $jumpboxExists = $true
}
$sqlExists = $false
if ("SQL Server" -in $instances.role){
    $sqlExists = $true
}

$deployJump = $false
$deploySql = $false
$killJump = $false

if ($jumpboxExists -and $sqlExists){
    Write-Output "      We already have a SQL and Jump server. No need to rebuild either."
    $deployJump = $false 
    $deploySql = $false 
    $killJump = $false
}

if ($jumpboxExists -and (-not $sqlExists)){
    Write-Output "      We have a jump server, but no SQL Server. Need to kill the old jump and build both new."
    $deployJump = $true
    $deploySql = $true
    $killJump = $true
}

if ((-not $jumpboxExists) -and $sqlExists){
    Write-Output "      We have a SQL server, but no Jump Server. Need to spawn a new jump server."
    $deployJump = $true
    $deploySql = $false
    $killJump = $false
}

if ((-not $jumpboxExists) -and (-not $sqlExists)){
    Write-Output "      We don't have a SQL Server or a Jump Server. Need to spawn both."
    $deployJump = $true
    $deploySql = $true
    $killJump = $false
}

# Calculating web servers to start/kill
$numExistingWebServers = ($instances | Where-Object { $_.role -like "Web Server" }).length

$webServersToKill = 0
$webServersToStart = 0

if ($numExistingWebServers -gt $numWebServers){
    # We have too many web servers. We need to whittle them down.
    $webServersToKill = $numExistingWebServers - $numWebServers
    Write-Output "      We already have $numExistingWebServers Web Servers but we only need $numWebServers. Need to kill $webServersToKill."
}
else {
    # We don't have enough web servers. We need to build more.
    $webServersToStart = $numWebServers - $numExistingWebServers
    Write-Output "      We already have $numExistingWebServers Web Servers but we need $numWebServers. Need to build $webServersToStart more."
}

##########     3. Removing everything that needs to be deleted     ##########

if ($killJump){
    Write-Output "      Removing the existing SQL Jumpbox(es)."
    $jumpServers = Get-Servers -role $dbJumpboxRole -environment $environment -includePending
    foreach ($jumpServer in $jumpServers){
        $id = $jumpServer.InstanceId
        $ip = $jumpServer.PublicIpAddress 
        Write-Output "        Removing EC2 instance $id at $ip."
        Remove-EC2Instance -InstanceId $id -Force | out-null
        Write-Output "        Removing Octopus Target for $ip."
        Remove-OctopusMachine -octoUrl $octoUrl -ip $ip -apiKey $octoApiKey
        # Removing terminated instance from the $instances datatable
        $instances.Select("id = '$id'").Delete()                
    }
}
if ($webServersToKill -gt 0){
    Write-Output "      Removing $webServersToKill web servers."
    $webServers = Get-Servers -role $webServerRole -environment $environment -includePending
    for ($i = 0; $i -lt $webServersToKill; $i++){
        $id = $webServers[$i].InstanceId
        $ip = $webServers[$i].PublicIpAddress 
        Write-Output "        Removing EC2 instance $id at $ip."
        Remove-EC2Instance -InstanceId $id -Force | out-null
        Write-Output "        Removing Octopus Target for $ip."
        Remove-OctopusMachine -octoUrl $octoUrl -ip $ip -apiKey $octoApiKey
        # Removing terminated instance from the $instances datatable
        $instances.Select("id = '$id'").Delete()                  
    }
}

##########     4. Adding anything that needs to be added     ##########

# Building all the servers
if($webServersToStart -gt 0){
    Write-Output "    Launching Web Server(s) with command: Start-Servers -role $webServerRole -ami $ami -environment $environment -encodedUserData *** -required $numWebServers"
    $webServerIds = Start-Servers -role $webServerRole -ami $ami -environment $environment -encodedUserData $webServerUserData -required $numWebServers   
    ForEach ($instanceId in $webServerIds){
        [void]$instances.Rows.Add($instanceId,"Pending","unassigned","Web Server","booting")
    }
}
if($deploySql){
    Write-Output "    Launching SQL Server with command: Start-Servers -role $dbServerRole -ami $ami -environment $environment -encodedUserData ***"
    $sqlServerIds = Start-Servers -role $dbServerRole -ami $ami -environment $environment -encodedUserData $dbServerUserData
    ForEach ($instanceId in $sqlServerIds){
        [void]$instances.Rows.Add($instanceId,"Pending","unassigned","SQL Server","booting")
    }
    if($deployJump){
        Write-Output "      (Waiting to launch SQL jumpbox server until we have an IP address for SQL Server instance)." 
    }
}

$instancesString = Get-InstancesString
Write-output $instancesString

Write-Output "      Waiting for instances to start... (This normally takes about 30 seconds.)"

$startTime = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
While ("pending" -in $instances.state){
    $pendingInstances = ($instances.Select("state = 'Pending'"))
    foreach ($instance in $pendingInstances){
        $instanceId = $instance.id
        $filter = @( @{Name="instance-id";Values=$instanceId} )
        $currentStatus = (Get-EC2Instance -Filter $filter).Instances
        if($currentStatus.state.name.value -like "running"){
            Write-Output "        Instance $instanceId has started"
            $instance["public_ip"] = $currentStatus.PublicIpAddress
            $instance["state"] = $currentStatus.state.name.value            
        }
    }
    $currentTime = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
    if (($currentTime - $startTime) -gt 60){
        Write-Error "It's taking an unusually long time for instances to start."
    }
    Start-Sleep 2
}

$sqlIp = ($instances.Select("role = 'SQL Server'")).public_ip

Write-Output "      SQL IP address is $sqlIp"

if($deployJump){
    Write-Output "    Launching DB Jumpbox with command: Start-Servers -role $dbJumpboxRole -ami $ami -environment $environment -encodedUserData ***"
    $jumpServerUserData = Get-UserData -fileName "VM_UserData_DbJumpbox.ps1" -octoUrl $octoUrl -role $dbJumpboxRole -sql_ip $sqlIp -environment $environment -octopusSqlPassword $octopusSqlPassword
    $jumpboxIds = Start-Servers -role $dbJumpboxRole -ami $ami -environment $environment -encodedUserData $jumpServerUserData  
    ForEach ($instanceId in $jumpboxIds){
        [void]$instances.Rows.Add($instanceId,"Pending","unassigned","DB Jumpbox","booting")
    }
}

##########     6. Waiting until everything comes back online     ##########

$startTime = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
While ("pending" -in $instances.state){
    $pendingInstances = ($instances.Select("state = 'Pending'"))
    foreach ($instance in $pendingInstances){
        $instanceId = $instance.id
        $filter = @( @{Name="instance-id";Values=$instanceId} )
        $currentStatus = (Get-EC2Instance -Filter $filter).Instances
        if($currentStatus.state.name.value -like "running"){
            Write-Output "        Instance $instanceId has started"
            $instance["public_ip"] = $currentStatus.PublicIpAddress
            $instance["state"] = $currentStatus.state.name.value            
        }
    }
    $currentTime = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
    if (($currentTime - $startTime) -gt 60){
        Write-Error "It's taking an unusually long time for instances to start."
    }
    Start-Sleep 2
}

$instancesString = Get-InstancesString
Write-output $instancesString

# So that anyone executing this runbook has a rough idea how long they can expect to wait
Write-Output "    Waiting for all instances to complete setup..."
Write-Output "      Setup should take roughly this long, but it can vary." 
Write-Output "         Web Servers:"
Write-Output "           setup-1/5-validatingSecrets (190-230 seconds)"
Write-Output "           setup-2/5-CreatingLocalUsers (190-230 seconds)"
Write-Output "           setup-3/5-SettingUpIIS  (200-230 seconds)"
Write-Output "           setup-4/5-SettingUpDotNetCore (360-400 seconds)"
Write-Output "           setup-5/5-InstallingTentacle (410-450 seconds)"
Write-Output "           ready (450-500 seconds)"
Write-Output "         SQL Servers:"
Write-Output "           setup-1/4-validatingSecrets (190-230 seconds)"
Write-Output "           setup-2/4-CreatingLocalUsers (190-230 seconds)"
Write-Output "           setup-3/4-InstallingChoco  (210-240 seconds)"
Write-Output "           setup-4/4-InstallingSqlServer (220-250 seconds)"
Write-Output "           ready (630-660 seconds)"
Write-Output "         DB Jumpboxes:"
Write-Output "           setup-1/4-validatingSecrets (240-270 seconds)"
Write-Output "           setup-2/4-CreatingLocalUsers (240-270 seconds)"
Write-Output "           setup-3/4-InstallingTentacle  (250-280 seconds)"
Write-Output "           setup-4/4-SettingUpSqlServer (310-330 seconds)"
Write-Output "           ready (630-660 seconds)"
Write-Output "      Note: Even when ready, some instances will install a few extra but unessential bits for convenience."
Write-Output "      (If it's taking significantly longer, review the log at C:/startup on the unresponsive instances.)"

$time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
$counter = 1
Write-Output "        $time seconds | begin polling for updates every 2 seconds..." 

$numReadyInstances = ($instances | Where-Object {$_.status -like "ready*"}).id.count
$numRequiredInstances = $instances.id.length

# Now we wait in a holding pattern until all instances have a status of either "ready*", or "terminated"
while ($numReadyInstances -lt $numRequiredInstances){
    Start-Sleep -s 2
    $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
    foreach ($instanceId in $instances.id) {
        $previousStatus = ($instances.Select("id = '$instanceId'")).status
        $currentStatus = (Get-EC2Tag -Filter @{Name="resource-id";Values=$instanceId},@{Name="key";Values="StartupStatus"}).Value
        if ($currentStatus -notlike $previousStatus ){
            $instances | Where-Object {$_.id -like $instanceId} | ForEach-Object {$_.status = $currentStatus}
            Write-output "        $time seconds | $role $instanceId is now in state: $currentStatus"
        }
        if ($currentStatus -like "*FAILED*"){
            Write-Warning "Uh oh, something went wrong with $instanceId. Status is: $currentStatus"
            $instancesString = Get-InstancesString
            Write-output $instancesString
            Write-Error "At least one instance has failed to start up correctly. Review all your EC2 instances and either terminate or fix them, then try again."
        }
    }
    $counter++

    $numReadyInstances = ($instances | Where-Object {$_.status -like "ready*"}).id.count
    
    if (($counter % 30) -eq 0){
        Write-Output "        $time seconds |   $numReadyInstances / $numRequiredInstances instances are ready. Still polling for updates every 2 seconds..."
    }

    if ($time -gt $timeout){
        Write-Error "Timed out at $time seconds. It shouldn't take this long. Compare expected times to the actual times for a hint at whether/where the process failed."
    }
}
Write-Output "All instances are ready."

##########     7. Final checks      #######################################

Write-Output "Performing a few final checks for Web Servers and DB Jumpboxes:"
$webServers = ($instances | Where-Object {($_.role -like "Web Server") -and ($_.status -like "ready*")})
$dbJumpboxes = ($instances | Where-Object {($_.role -like "DB Jumpbox") -and ($_.status -like "ready*")})

ForEach ($dbJumpbox in $dbJumpboxes){
    
    $id = $dbJumpbox.id
    $ip = $dbJumpbox.public_ip
    Write-Output "  DB Jumpbox $id at $ip..."
    Write-Output "    Checking tentacle is configured correctly."
    if (-not (Test-Tentacle -ip $ip -octoUrl $octoUrl -apiKey $octoApiKey)){
        Write-Warning "      Uh oh: It doesn't look like the tentacle registered with Octopus? Double-check the Infrastucture tab and look for a tentacle at $ip."
    }
    Write-Output "    Upgrading Calamari on tentacle."
    Update-Calamari -ip $ip -OctopusUrl $octoUrl -ApiKey $octoApiKey
}

ForEach ($webServer in $webServers){
    $id = $webServer.id
    $ip = $webServer.public_ip
    Write-Output "  Web Server $id at $ip..."
    Write-Output "    Checking default IIS page is available."
    if (-not (Test-IIS -ip $ip)){
        Write-Warning "      Uh oh: It doesn't look like IIS is running? Try navigating to $ip in a web browser."
    }
    Write-Output "    Checking tentacle is configured correctly."
    if (-not (Test-Tentacle -ip $ip -octoUrl $octoUrl -apiKey $octoApiKey)){
        Write-Warning "      Uh oh: It doesn't look like the tentacle registered with Octopus? Double-check the Infrastucture tab and look for a tentacle at $ip."
    }
    Write-Output "    Upgrading Calamari on tentacle."
    Update-Calamari -ip $ip -OctopusUrl $octoUrl -ApiKey $octoApiKey
}
    
Write-Output "SUCCESS!"
Write-Output "*"

$instancesString = Get-InstancesString
Write-output $instancesString