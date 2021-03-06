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
$checkSql = $true
if ($octopusSqlPassword -like ""){
    try {
        [SecureString]$octopusSqlPassword = $OctopusParameters["OCTOPUS_SQL_PASSWORD"] | ConvertTo-SecureString -AsPlainText -Force
    }
    catch {
        Write-Warning "No octopus password provided for SQL Server. Skipping check to see if/when SQL Server comes online"
        [SecureString]$octopusSqlPassword = "The wrong password!" | ConvertTo-SecureString -AsPlainText -Force # Need to convert to secure string to avoid errors
        $checkSql = $false
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

##########     2. Determine how many machines need to be added/deleted     ##########

Write-Output "    Checking required infrastucture changes..."

# Calculating what infra we already have 
$existingVmsHash = Get-ExistingInfraTotals -environment $environment -rolePrefix $rolePrefix
$writeableExistingVms = Write-InfraInventory -vmHash $existingVmsHash
Write-Output "      Existing VMs: $writeableExistingVms"

# Checking the total infra requirement
$requiredVmsHash = Get-RequiredInfraTotals -numWebServers $numWebServers
$writeableRequiredVms = Write-InfraInventory -vmHash $requiredVmsHash
Write-Output "      Required VMs: $writeableRequiredVms"

# Checking whether we need a new SQL machine
$deploySql = $false
if ($existingVmsHash.sqlVms -eq 0){
    Write-Output "        SQL Server deployment is required."
    $deploySql = $true
}
else {
    Write-Output "        SQL Server is already running."
}
# Checking whether we need a new SQL Jumpbox and whether we need to kill the existing one
$deployJump = $false
$killJump = $false
if ($existingVmsHash.jumpVms -eq 0){
    Write-Output "        SQL Jumpbox deployment is required."
    $deployJump = $true
}
if ($deploySql -and (-not $deployJump)){
    Write-Output "        New SQL Server instance being deployed so killing and respawning the SQL Jumpbox as well."
    $killJump = $true
    $deployJump = $true    
}
if ($existingVmsHash.jumpVms -gt 1){
    $totalJumpboxes = $existingVmsHash.jumpVms
    Write-Warning "Looks like we already have $totalJumpboxes jumpboxes, but we only want 1. Will kill them all and re-deploy"
    $killJump = $true
    $deployJump = $true 
}
if (-not $deployJump) {
    Write-Output "        SQL Jumpbox is already running."
}

# Calculating web servers to start/kill
$webServersToKill = 0
$webServersToStart = 0
if ($requiredVmsHash.webVms -gt $existingVmsHash.webVms){
    $webServersToStart = $requiredVmsHash.webVms - $existingVmsHash.webVms
    Write-Output "        Need to add $webServersToStart web servers."
}
if ($requiredVmsHash.webVms -lt $existingVmsHash.webVms){
    $webServersToKill = $existingVmsHash.webVms - $requiredVmsHash.webVms
    Write-Output "        Too many web servers currently running. Need to remove $webServersToKill web servers."
}
if ($requiredVmsHash.webVms -eq $existingVmsHash.webVms){
    Write-Output "        Correct number of web servers are already running."
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
    }
}

##########     4. Adding anything that needs to be added     ##########

# Creating a datatable object to keep track of the status of all our instances
$instances = New-Object System.Data.Datatable
[void]$instances.Columns.Add("id")
[void]$instances.Columns.Add("state")
[void]$instances.Columns.Add("public_ip")
[void]$instances.Columns.Add("role")
[void]$instances.Columns.Add("status")

# Building all the servers
if($webServersToStart -gt 0){
    Write-Output "    Launching Web Server(s) with command: Start-Servers -role $webServerRole -ami $ami -environment $environment -encodedUserData *** -required $numWebServers"
    $webServerIds = Start-Servers -role $webServerRole -ami $ami -environment $environment -encodedUserData $webServerUserData -required $numWebServers   
    ForEach ($instanceId in $webServerIds){
        [void]$instances.Rows.Add($instanceId,"Pending","unassigned","Web Server","")
    }
}
if($deploySql){
    Write-Output "    Launching SQL Server with commend: Start-Servers -role $dbServerRole -ami $ami -environment $environment -encodedUserData ***"
    $sqlServerIds = Start-Servers -role $dbServerRole -ami $ami -environment $environment -encodedUserData $dbServerUserData
    ForEach ($instanceId in $sqlServerIds){
        [void]$instances.Rows.Add($instanceId,"Pending","unassigned","SQL Server","")
    }
    if($deployJump){
        Write-Output "      (Waiting to launch SQL jumpbox server until we have an IP address for SQL Server instance)." 
    }
}

Write-Output $instances

Write-Output "      Waiting for instances to start... (This normally takes about 30 seconds.)"

$startTime = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
While ("pending" -in $instances.state){
    $pendingInstances = ($instances.Select("state = 'Pending'"))
    foreach ($instance in $pendingInstances){
        $instanceId = $instance.id
        $filter = @( @{Name="instance-id";Values=$instanceId} )
        $currentStatus = (Get-EC2Instance -Filter $filter).Instances
        if($currentStatus.state.name.value -like "running"){
            Write-Output "Instance $instanceId has started"
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

$sqlIp = $previousStatus = ($instances.Select("role = 'SQL Server")).public_ip

if($deployJump){
    Write-Output "    Launching DB Jumpbox with commend: Start-Servers -role $dbJumpboxRole -ami $ami -environment $environment -encodedUserData ***"
    $jumpServerUserData = Get-UserData -fileName "VM_UserData_DbJumpbox.ps1" -octoUrl $octoUrl -role $dbJumpboxRole -sql_ip $sqlIp -environment $environment -octopusSqlPassword $octopusSqlPassword
    $jumpboxIds = Start-Servers -role $dbJumpboxRole -ami $ami -environment $environment -encodedUserData $jumpServerUserData  
    ForEach ($instanceId in $jumpboxIds){
        [void]$instances.Rows.Add($instanceId,"Pending","unassigned","DB Jumpbox","")
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
            Write-Output "Instance $instanceId has started"
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

# So that anyone executing this runbook has a rough idea how long they can expect to wait
Write-Output "    Waiting for all instances to complete setup..."
Write-Output "      Setup should take roughly this long, but it can vary." 
Write-Output "         Web Servers:"
Write-Output "           setup-1/5-validatingSecrets (190-220 seconds)"
Write-Output "           setup-2/5-CreatingLocalUsers (190-220 seconds)"
Write-Output "           setup-3/5-SettingUpIIS  (200-230 seconds)"
Write-Output "           setup-4/5-SettingUpDotNetCore (320-350 seconds)"
Write-Output "           setup-5/5-InstallingTentacle (370-400 seconds)"
Write-Output "           ready (450-500 seconds)"
Write-Output "         SQL Servers:"
Write-Output "           setup-1/4-validatingSecrets (190-220 seconds)"
Write-Output "           setup-2/4-CreatingLocalUsers (190-220 seconds)"
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
Write-Output "$time seconds | begin polling for updates every 2 seconds..." 

while ($instances.status.length -ne ($instances | Where-Object { $_.status -like "ready*" }).length){
    Start-Sleep -s 2
    $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
    foreach ($instanceId in $instances.id) {
        $currentStatus = (Get-EC2Tag -Filter @{Name="resource-id";Values=$instanceId},@{Name="key";Values="StartupStatus"}).Value
        $previousStatus = ($instances.Select("id = '$instanceId'")).status
        if ($currentStatus -notlike $previousStatus ){
            $thisVm = ($instances.Select("id = '$instanceId'"))
            $thisVm[0]["status"] = $currentStatus
            $role = ($instances.Select("id = '$instanceId'")).role
            Write-output "$time seconds | $role $instanceId is now in state: $currentStatus"
        }
        if ($currentStatus -like "*FAILED*"){
            Write-Warning "Uh oh, something went wrong with $instanceId. Status is: $currentStatus"
            Write-Output $instances
            Write-Error "At least one instance has failed to start up correctly. Review all your EC2 instances and either terminate or fix them, then try again."
        }
    }
    $counter++
    if (($counter % 30) -eq 0){
        Write-Output "$time seconds | (still polling for updates every 2 seconds)" 
    }
    if ($time -gt 1500){
        Write-Error "Timed out at $time seconds. It shouldn't take this long. Compare expected times to the actual times for a hint at whether/where the process failed."
    }
}

Write-Output "SUCCESS!"
Write-Output $instances






<# OLD IMPLEMENTATION for part 6 (waiting)

if ($deployJump){
    # Checking to see if the jumpbox came online
    $dbJumpboxInstances = Get-Servers -role $dbJumpboxRole -environment $environment -includePending
    if ($dbJumpboxInstances.count -ne 1){
        $instancesFailed = $true
        $num = $dbJumpboxInstances.count
        $errMsg = "$errMsg Expected 1 SQL Jumpbox instance but have $num instance(s)."
    }
    $jumpboxRunning = $false
    $runningDbJumpboxInstances = @()
    While (-not $jumpboxRunning){

        $runningDbJumpboxInstances = Get-Servers -role $dbJumpboxRole -environment $environment
        $NumRunning = $runningDbJumpboxInstances.count

        if ($NumRunning -eq 1){
            $jumpboxRunning = $true
            $jumpIp = $runningDbJumpboxInstances[0].PublicIpAddress

            # Logging all the IP addresses
            Write-Output "    SQL Jumpbox is running!"
            Write-Output "      SQL Jumpbox: $jumpIp"
            break
        }
        else {
            Write-Output "      Waiting for SQL Jumpbox to start..."
        }
        Start-Sleep -s 15
    }
}

# Creating a datatable object to keep track of the status of all our VMs
$vms = New-Object System.Data.Datatable
[void]$vms.Columns.Add("ip")
[void]$vms.Columns.Add("role")
[void]$vms.Columns.Add("sql_running")
[void]$vms.Columns.Add("iis_running")
[void]$vms.Columns.Add("tentacle_listening")

# Only check of SQL is running if we have been given a password for SQL Server
$sqlrunning = $null
if ($checkSql){
    $sqlrunning = $false
}

# SQL Server instances need SQL Server, but not IIS or a tentacle
ForEach ($instance in $runningDbServerInstances){
    [void]$vms.Rows.Add($instance.PublicIpAddress,$dbServerRole,$sqlrunning,$null,$null)
}
# SQL Jumpboxes need a tentacle, but not SQL Server or IIS 
ForEach ($instance in $runningDbJumpboxInstances){
    [void]$vms.Rows.Add($instance.PublicIpAddress,$dbJumpboxRole,$null,$null,$false)
}
# Web Servers need a tentacle and IIS, but not SQL Server 
ForEach ($instance in $runningWebServerInstances){
    [void]$vms.Rows.Add($instance.PublicIpAddress,$webServerRole,$null,$false,$false)
}

# So that anyone executing this runbook has a rough idea how long they can expect to wait
Write-Output "    Waiting for all instances to complete setup..."
Write-Output "      Setup usually takes roughly:"
Write-Output "         - SQL Jumpbox tentacles:     270-330 seconds"
Write-Output "         - Web server IIS installs:   350-400 seconds"
Write-Output "         - Web server tentacles:      450-500 seconds"
Write-Output "         - SQL Server install:        600-750 seconds"

# Waiting to see if they all come online
$allVmsConfigured = $false
$runningWarningGiven = $false
$sqlCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "octopus", $octopusSqlPassword
$sqlDeployed = $false

While (-not $allVmsConfigured){
    # Checking whether SQL Server is online yet
    $pendingSqlServers = $vms.Select("sql_running like '$false'")
    forEach ($ip in $pendingSqlServers.ip){
        $sqlDeployed = Test-SQL -ip $ip -cred $sqlCred
        if ($sqlDeployed){
            Write-Output "      SQL Server is listening at: $ip"
            $thisVm = ($vms.Select("ip = '$ip'"))
            $thisVm[0]["sql_running"] = $true
        }
    }

    # Checking whether any IIS instances have come online yet
    $pendingIisInstalls = $vms.Select("iis_running like '$false'")
    forEach ($ip in $pendingIisInstalls.ip){
        $iisDeployed = Test-IIS -ip $ip
        if ($iisDeployed){
            Write-Output "      IIS is running on web server: $ip"
            $thisVm = ($vms.Select("ip = '$ip'"))
            $thisVm[0]["iis_running"] = $true
        }
    }

    # Checking whether any new tentacles have come online yet
    $pendingTentacles = $vms.Select("tentacle_listening like '$false'")
    forEach ($ip in $pendingTentacles.ip){
        $tentacleDeployed = Test-Tentacle -ip $ip -octoUrl $octoUrl -ApiKey $octoApiKey
        if ($tentacleDeployed){
            $thisVm = ($vms.Select("ip = '$ip'"))
            $thisVm[0]["tentacle_listening"] = $true
            $thisVmRole = "Web server"
            if ($thisVm[0]["role"] -like "*jump*"){
                $thisVmRole = "SQL Jumpbox"
            }
            Write-Output "      $thisVmRole tentacle is listening on: $ip"
        }
    }

    # Getting the time
    $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))

    # Logging the current status
    ## SQL Server
    $currentStatus = "$time seconds | "
    if ($sqlDeployed){
        $currentStatus = "$currentStatus SQL Server: Running  - "
    } 
    else {
        $currentStatus = "$currentStatus SQL Server: Pending  - "
    }
    ## IIS
    $vmsWithIis = ($vms.Select("iis_running = '$true'"))
    $numIisInstalls = $vmsWithIis.count
    $currentStatus = "$currentStatus IIS Installs: $numIisInstalls/$numWebServers  - "
    ## Tentacles
    $vmsWithTentacles = ($vms.Select("tentacle_listening = '$true'"))
    $numTentacles = $vmsWithTentacles.count
    $tentaclesRequired = $numWebServers + 1 # (All the web servers plus the SQL Jumpbox)
    $currentStatus = "$currentStatus Tentacles deployed: $numTentacles/$tentaclesRequired"
    Write-Output "        $currentStatus"
    
    # Checking if there is anything left that needs to be configured on any VMs
    $allVmsConfigured = $true
    ForEach ($vm in $vms){
        if ($vm.ItemArray -contains "False"){
            $allVmsConfigured = $false
        }
    }
    if ($allVmsConfigured){
        break
    }

    # Writing a warning if this is taking a suspiciously long time 
    if (($time -gt 1200) -and (-not $runningWarningGiven)){
        Write-Warning "EC2 instances are taking an unusually long time to start."
        $runningWarningGiven = $true
    }

    # Giving up if we've passed the timeout
    if (($time -gt $timeout)-and (-not $allVmsConfigured)){
        Write-Error "Timed out. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
    }   

    # If we've got this far, we are still waiting for something. Sleeping for a few seconds before checking again.
    Start-Sleep -s 10
}

##########     7. Verify that we have the correct number of machines     ##########
Write-Output "    Verifying infrastructure:"

# Calculating the total infra requirement
$existingVmsHash = Get-ExistingInfraTotals -environment $environment -rolePrefix $rolePrefix
$writeableExistingVms = Write-InfraInventory -vmHash $existingVmsHash
Write-Output "      Existing VMs: $writeableExistingVms"

$requiredVmsHash = Get-RequiredInfraTotals -numWebServers $numWebServers
$writeableRequiredVms = Write-InfraInventory -vmHash $requiredVmsHash
Write-Output "      Required VMs: $writeableRequiredVms"

$runningDbServerInstances = Get-Servers -role $dbServerRole -environment $environment
$dbJumpboxInstances = Get-Servers -role $dbJumpboxRole -environment $environment -includePending
$runningWebServerInstances = Get-Servers -role $webServerRole -environment $environment
$msg = "        SQL Server: " + $runningDbServerInstances[0].PublicIpAddress
Write-Output $msg 
$msg = "        SQL Jumpbox: " + $dbJumpboxInstances[0].PublicIpAddress
Write-Output $msg 
ForEach ($instance in $runningWebServerInstances){
    $msg = "        Web server: " + $instance.PublicIpAddress
    Write-Output $msg
}

# And did it work?
if ($writeableRequiredVms -like $writeableExistingVms){
    Write-Output "SUCCESS! All instances are present and correct."
}
else {
    Write-Error "FAILED! The numbers of required and existing VMs do not match."
}

#>