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
    $sqlOctoPassword = "",
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
if ($sqlOctoPassword -like ""){
    try {
        [SecureString]$sqlOctoPassword = $OctopusParameters["sqlOctopusPassword"] | ConvertTo-SecureString -AsPlainText -Force
    }
    catch {
        Write-Warning "No octopus password provided for SQL Server. Skipping check to see if/when SQL Server comes online"
        [SecureString]$sqlOctoPassword = "The wrong password!" | ConvertTo-SecureString -AsPlainText -Force # Need to convert to secure string to avoid errors
        $checkSql = $false
    }
}
else {
    [SecureString]$sqlOctoPassword = $sqlOctoPassword | ConvertTo-SecureString -AsPlainText -Force # The param should really have been a SecureString to begin with...
}

# Infering the roles
$webServerRole = "$rolePrefix-WebServer"
$dbServerRole = "$rolePrefix-DbServer"
$dbJumpboxRole = "$rolePrefix-DbJumpbox"

# Reading and encoding the VM startup scripts
$webServerUserData = Get-UserData -fileName "VM_UserData_WebServer.ps1" -octoUrl $octoUrl -role $webServerRole
$dbServerUserData = Get-UserData -fileName "VM_UserData_DbServer.ps1" -octoUrl $octoUrl -role $dbServerRole

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

# Building all the servers
if($deploySql){
    Write-Output "    Launching SQL Server"
    Start-Servers -role $dbServerRole -ami $ami -environment $environment -encodedUserData $dbServerUserData
    if($deployJump){
        Write-Output "      (Waiting to launch SQL jumpbox server until we have an IP address for SQL Server instance)." 
    }
}

if($webServersToStart -gt 0){
    Write-Output "    Launching Web Server(s)"
    Start-Servers -role $webServerRole -ami $ami -environment $environment -encodedUserData $webServerUserData -required $numWebServers   
}

# Checking all the instances
$dbServerInstances = Get-Servers -role $dbServerRole -environment $environment -includePending
$webServerInstances = Get-Servers -role $webServerRole -environment $environment -includePending

# Logging all the instance details
Write-Output "      Verifying instances: "
ForEach ($instance in $dbServerInstances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "        SQL Server $id is in state: $state"
}

ForEach ($instance in $webServerInstances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "        Web server $id is in state: $state"
}

# Checking we've got all the right SQL and Web instances
$instancesFailed = $false
$errMsg = ""
if ($dbServerInstances.count -ne 1){
    $instancesFailed = $true
    $num = $dbServerInstances.count
    $errMsg = "$errMsg Expected 1 SQL Server instance but have $num instance(s)."
}
if ($webServerInstances.count -ne $numWebServers){
    $instancesFailed = $true
    $num = $webServerInstances.count
    $errMsg = "$errMsg Expected $numWebServers Web Server instance(s) but have $num instance(s)."
}
if ($instancesFailed){
    Write-Error $errMsg
}
else {
    Write-Output "    All SQL and web servers launched successfully!"
}

Write-Output "      Waiting for instances to start... (This normally takes about 30 seconds.)"

$allRunning = $false
$runningDbServerInstances = @()
$runningWebServerInstances = @()
$sqlIp = ""

While (-not $allRunning){
    $totalRequired = $numWebServers + 1 # Web Servers + SQL Server.
                                        # We'll launch the jumpbox after we know the SQL IP address.

    $runningDbServerInstances = Get-Servers -role $dbServerRole -environment $environment
    $runningWebServerInstances = Get-Servers -role $webServerRole -environment $environment

    $NumRunning = $runningDbServerInstances.count + $runningWebServerInstances.count

    if ($NumRunning -eq ($totalRequired)){
        $allRunning = $true
        $sqlIp = $runningDbServerInstances[0].PublicIpAddress

        $webIps = ""
        ForEach ($instance in $runningWebServerInstances){
            $thisIp = $instance.PublicIpAddress
            if ($webIps -like ""){
                $webIps = "$thisIp" # The first IP address in the list
            }
            else {
                $webIps = "$webIps, $thisIp" # All subsequent IP addresses
            }
        }

        # Logging all the IP addresses
        Write-Output "    SQL Server machine and all web servers are running!"
        Write-Output "      SQL Server: $sqlIp"
        Write-Output "      Web Server(s): $webIps"
        break
    }
    else {
        Write-Output "        $NumRunning out of $totalRequired instances are running."
    }
    Start-Sleep -s 15
}

# Now we know the SQL Server IP, we can launch the jumpbox
if ($deployJump){
    Write-Output "    Launching SQL Jumpbox"
    $jumpServerUserData = Get-UserData -fileName "VM_UserData_DbJumpbox.ps1" -octoUrl $octoUrl -role $dbJumpboxRole -sql_ip $sqlIp
    Start-Servers -role $dbJumpboxRole -ami $ami -environment $environment -encodedUserData $jumpServerUserData  
}

########   5. Installing dbatools so that we can ping SQL Server to see when it comes online   ########    ##########

try {
    Import-Module dbatools
}
catch {
    Write-Output "    Installing dbatools so that we can ping SQL Server..."
    Write-Output "      (This takes a couple of minutes)"
    Install-Module dbatools -Force
}
try {
    Import-Module dbatools
    Update-Dbatools -EnableException
    Write-Output "      dbatools is ready for use"
}
catch {
    Write-Error "Failed to install dbatools: $Error[0]"
}

##########     6. Waiting until everything comes back online     ##########

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
$sqlCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "octopus", $sqlOctoPassword
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

