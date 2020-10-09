param(
    $instanceType = "t2.micro", # 1 vCPU, 1GiB Mem, free tier elligible: https://aws.amazon.com/ec2/instance-types/
    $ami = "ami-0d2455a34bf134234", # Microsoft Windows Server 2019 Base with Containers
    $numWebServers = 1,
    $timeout = 1800, # 30 minutes, in seconds
    $octoApiKey = "",
    $sqlSaPassword = "",
    $sqlOctoPassword = "",
    $octoUrl = "",
    $envId = "",
    $environment = "Manual run"
)

$ErrorActionPreference = "Stop"
$stopwatch =  [system.diagnostics.stopwatch]::StartNew()

# Initialising variables
$rolePrefix = ""
try {
    $rolePrefix = $OctopusParameters["Octopus.Project.Name"]
}
catch {
    $rolePrefix = "RandomQuotes_SQL"
}

$tagValue = ""
try {
    $tagValue = $OctopusParameters["Octopus.Environment.Name"]
}
catch {
    $tagValue = $environment
}

if ($octoUrl -like ""){
    try {
        $octoUrl = $OctopusParameters["Octopus.Web.ServerUri"]
    }
    catch {
        Write-Error "Please provide a value for -octoUrl"
    }
}

if ($envId = ""){
    try {
        $envId = $OctopusParameters["Octopus.Environment.Id"]
    }
    catch {
        Write-Error "Please provide a value for -octoApiKey"
    }
}

if ($octoApiKey -like ""){
    try {
        $octoApiKey = $OctopusParameters["API_KEY"]
    }
    catch {
        Write-Error "Please provide a value for -octoApiKey"
    }
}

$checkSql = $true
if ($sqlSaPassword -like ""){
    try {
        $sqlSaPassword = $OctopusParameters["sqlSaPassword"] | ConvertTo-SecureString -AsPlainText -Force
    }
    catch {
        Write-Warning "No sa password provided for SQL Server. Skipping check to see if/when SQL Server comes online"
        $checkSql = $false    
    }
}

$checkLogins = $true
if ($sqlOctoPassword -like ""){
    try {
        $sqlOctoPassword = $OctopusParameters["sqlOctopusPassword"] | ConvertTo-SecureString -AsPlainText -Force
    }
    catch {
        Write-Warning "No octopus password provided for SQL Server. Skipping check to see if/when SQL Server comes online"
        $checkLogins = $false
    }
}

$webServerRole = "$rolePrefix-WebServer"
$dbServerRole = "$rolePrefix-DbServer"
$dbJumpboxRole = "$rolePrefix-DbJumpbox"

# Helper function to read and encoding the VM startup scripts
Function Get-UserData {
    param (
        $fileName,
        $role
    )
    
    # retrieving raw source code
    $userDataPath = "$PSScriptRoot\$filename"
    if (-not (Test-Path $userDataPath)){
        Write-Error "No UserData (VM startup script) found at $userDataPath!"
    }
    $userData = Get-Content -Path $userDataPath -Raw
    
    # replacing placeholder text
    $userData = $userData.replace("__OCTOPUSURL__",$octoUrl)
    $userData = $userData.replace("__ENV__",$tagValue)
    $userData = $userData.replace("__ROLE__",$role)

    # Base 64 encoding the userdata file (required by EC2)
    $encodedDbUserData = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($userData))

    # returning encoded userdata
    return $encodedDbUserData
}

# Reading and encoding the VM startup scripts
$webServerUserData = Get-UserData -fileName "VM_UserData_WebServer.ps1" -role $webServerRole
$dbServerUserData = Get-UserData -fileName "VM_UserData_DbServer.ps1" -role $dbServerRole
$jumpServerUserData = Get-UserData -fileName "VM_UserData_DbJumpbox.ps1" -role $dbJumpboxRole

# Helper function to get all the existing servers of a particular role
Function Get-Servers {
    param (
        $role,
        $value = $tagValue,
        [switch]$includePending
    )
    $acceptableStates = "running"
    if($includePending){
        $acceptableStates = @("pending", "running")
    }
    $instances = (Get-EC2Instance -Filter @{Name="tag:$role";Values=$value}, @{Name="instance-state-name";Values=$acceptableStates}).Instances 
    return $instances
}

# Helper function to build any servers that don't already exist
Function Build-Servers {
    param (
        $role,
        $value = $tagValue,
        $encodedUserData,
        $required = 1
    )
    $existingServers = Get-Servers -role $role -value $value -includePending
    $required = $required - $existingServers.count
    if ($required -gt 0){
        $NewInstance = New-EC2Instance -ImageId $ami -MinCount $required -MaxCount $required -InstanceType $instanceType -UserData $encodedUserData -KeyName RandomQuotes_SQL -SecurityGroup RandomQuotes_SQL -IamInstanceProfile_Name RandomQuotes_SQL
        # Tagging all the instances
        ForEach ($InstanceID  in ($NewInstance.Instances).InstanceId){
            New-EC2Tag -Resources $( $InstanceID ) -Tags @(
                @{ Key=$role; Value=$value}
            );
        }
    }    
}

# Building all the servers
Write-Output "    Launching SQL Server"
Build-Servers -role $dbServerRole -encodedUserData $dbServerUserData 
Write-Output "    Launching SQL Jumpbox"
Build-Servers -role $dbJumpboxRole -encodedUserData $jumpServerUserData
Write-Output "    Launching Web Server(s)"
Build-Servers -role $webServerRole -encodedUserData $webServerUserData -required $numWebServers

# Checking all the instances
$dbServerInstances = Get-Servers -role $dbServerRole -includePending
$dbJumpboxInstances = Get-Servers -role $dbJumpboxRole -includePending
$webServerInstances = Get-Servers -role $webServerRole -includePending

# Logging all the instance details
Write-Output "      Verifying instances: "
ForEach ($instance in $dbServerInstances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "        SQL Server $id is in state: $state"
}

ForEach ($instance in $dbJumpboxInstances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "        SQL Jumpbox $id is in state: $state"
}

ForEach ($instance in $webServerInstances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "        Web server $id is in state: $state"
}

# Checking we've got all the right instances
$instancesFailed = $false
$errMsg = ""
if ($dbServerInstances.count -ne 1){
    $instancesFailed = $true
    $num = $dbServerInstances.count
    $errMsg = "$errMsg Expected 1 SQL Server instance but have $num instance(s)."
}
if ($dbJumpboxInstances.count -ne 1){
    $instancesFailed = $true
    $num = $dbJumpboxInstances.count
    $errMsg = "$errMsg Expected 1 SQL Jumpbox instance but have $num instance(s)."
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
    Write-Output "    All instances launched successfully!"
}

Write-Output "      Waiting for instances to start... (This normally takes about 30 seconds.)"

$allRunning = $false
$runningDbServerInstances = @()
$runningDbJumpboxInstances = @()
$runningWebServerInstances = @()

While (-not $allRunning){
    $totalRequired = $numWebServers + 2 # Web Servers + Jumpbox + SQL Server

    $runningDbServerInstances = Get-Servers -role $dbServerRole
    $runningDbJumpboxInstances = Get-Servers -role $dbJumpboxRole
    $runningWebServerInstances = Get-Servers -role $webServerRole

    $NumRunning = $runningDbServerInstances.count +  $runningDbJumpboxInstances.count + $runningWebServerInstances.count

    if ($NumRunning -eq ($totalRequired)){
        $allRunning = $true
        $sqlIp = $runningDbServerInstances[0].PublicIpAddress
        $jumpIp = $runningDbJumpboxInstances[0].PublicIpAddress

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
        Write-Output "    All instances are running!"
        Write-Output "      SQL Server: $sqlIp"
        Write-Output "      SQL Jumpox: $jumpIp"
        Write-Output "      Web Server(s): $webIps"
        break
    }
    else {
        Write-Output "        $NumRunning out of $totalRequired instances are running."
    }
    Start-Sleep -s 15
}

# Installing dbatools PowerShell module so that we can ping sql server instance
try {
    Import-Module dbatools
}
catch {
    Write-Output "    Installing dbatools so that we can ping SQL Server..."
    Write-Output "      (This takes a couple of minutes)"
    Install-Module dbatools -Force
}

# Populating our table of VMs
$vms = New-Object System.Data.Datatable
[void]$vms.Columns.Add("ip")
[void]$vms.Columns.Add("role")
[void]$vms.Columns.Add("sql_running")
[void]$vms.Columns.Add("sql_logins")
[void]$vms.Columns.Add("iis_running")
[void]$vms.Columns.Add("tentacle_listening")

$sqlrunning = $null
if ($checkSql){
    $sqlrunning = $false
}
$sqlLogins = $null
if ($checkLogins){
    $sqlLogins = $false
}


ForEach ($instance in $runningDbServerInstances){
    [void]$vms.Rows.Add($instance.PublicIpAddress,$dbServerRole,$sqlrunning,$sqlLogins,$null,$null)
}
ForEach ($instance in $runningDbJumpboxInstances){
    [void]$vms.Rows.Add($instance.PublicIpAddress,$dbJumpboxRole,$null,$null,$null,$false)
}
ForEach ($instance in $runningWebServerInstances){
    [void]$vms.Rows.Add($instance.PublicIpAddress,$webServerRole,$null,$null,$false,$false)
}
        
Write-Output "    Waiting for all instances to complete setup..."
Write-Output "      Once an instance is running, setup normally takes:"
Write-Output "        - Jumpbox tentacles: 4 min"
Write-Output "        - Web server IIS installs: 6-7 min"
Write-Output "        - Web server tentacles: 7-8 min"
Write-Output "        - SQL Server install: 9-11 min"
Write-Output "        - SQL Server logins: 3-4 min after SQL Server install"

# Helper functions to ping the instances
function Test-SQL {
    param (
        $ip,
        $cred
    )
    try { 
        Invoke-DbaQuery -SqlInstance $ip -Query 'SELECT @@version' -SqlCredential $cred -EnableException -QueryTimeout 1
    }
    catch {
        return $false
    }
    return $true
}

function Test-IIS {
    param (
        $ip
    )
    try { 
        $content = Invoke-WebRequest -Uri $ip -TimeoutSec 1 -UseBasicParsing
    }
    catch {
        return $false
    }
    if ($content.toString() -like "*iisstart.png*"){
    return $true
    }
}

function Test-Tentacle {
    param (
        $ip
    )
    $header = @{ "X-Octopus-ApiKey" = $octoApiKey }
    $uri = "https://" + $ip + ":10933/"
    $environmentMachines = "/api/Spaces-1/environments/$envId/machines"
    $machines = ((Invoke-WebRequest ($octoUrl + $environmentMachines) -Headers $header -UseBasicParsing).content | ConvertFrom-Json).items
    $uriList = @()
    $uriList += $machines.Uri 
    if ($uriList -contains $uri){
        return $true
    }
    else {
        return $false
    }
}

# Waiting to see if they all come online
$allVmsConfigured = $false
$runningWarningGiven = $false
$saCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "sa", $sqlSaPassword
$octoCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "octopus", $sqlOctoPassword
$sqlDeployed = $false
$loginsDeployed = $false

While (-not $allVmsConfigured){
    # Checking whether anything new has come online
    ## SQL Server
    $pendingSqlVms = $vms.Select("sql_running like '$false'")
    forEach ($ip in $pendingSqlVms.ip){
        $sqlDeployed = Test-SQL -ip $ip -cred $saCred
        if ($sqlDeployed){
            Write-Output "      SQL Server is running on: $ip"
            $thisVm = ($vms.Select("ip = '$ip'"))
            $thisVm[0]["sql_running"] = $true
        }
    }
    
    ## SQL Logins
    $pendingSqlLogins = $vms.Select("sql_logins like '$false'")
    forEach ($ip in $pendingSqlLogins.ip){
        $loginsDeployed = Test-SQL -ip $ip -cred $octoCred
        if ($loginsDeployed){
            Write-Output "      SQL Server Logins deployed to: $ip"
            $thisVm = ($vms.Select("ip = '$ip'"))
            $thisVm[0]["sql_logins"] = $true
        }
    }

    ## IIS
    $pendingIisInstalls = $vms.Select("iis_running like '$false'")
    forEach ($ip in $pendingIisInstalls.ip){
        $iisDeployed = Test-IIS -ip $ip
        if ($iisDeployed){
            Write-Output "      IIS is running on: $ip"
            $thisVm = ($vms.Select("ip = '$ip'"))
            $thisVm[0]["iis_running"] = $true
        }
    }

    ## Tentacles
    $pendingTentacles = $vms.Select("tentacle_listening like '$false'")
    forEach ($ip in $pendingTentacles.ip){
        $tentacleDeployed = Test-Tentacle -ip $ip
        if ($tentacleDeployed){
            Write-Output "      Tentacle is listening on: $ip"
            $thisVm = ($vms.Select("ip = '$ip'"))
            $thisVm[0]["tentacle_listening"] = $true
        }
    }

    # Checking if there is anything left that needs to be configured on any VMs
    $allVmsConfigured = $true
    ForEach ($vm in $vms){
        if ($vm.ItemArray -contains "False"){
            $allVmsConfigured = $false
        }
    }

    # Getting the time
    $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))

    if (-not $allVmsConfigured){
        # Working out the current status
        ## SQL Server
        $currentStatus = ""
        if ($sqlDeployed){
            $currentStatus = "SQL Server: Running,"
        } 
        else {
            $currentStatus = "SQL Server: Pending,"
        }
        ## SQL Logins
        if ($loginsDeployed){
            $currentStatus = "$currentStatus SQL Logins: Deployed,"
        } 
        else {
            $currentStatus = "$currentStatus SQL Logins: Pending,"
        }
        ## IIS
        $vmsWithIis = ($vms.Select("iis_running = '$true'"))
        $numIisInstalls = $vmsWithIis.count
        $currentStatus = "$currentStatus IIS Installs: $numIisInstalls / $numWebServers, "
        ## Tentacles
        $vmsWithTentacles = ($vms.Select("tentacle_listening = '$true'"))
        $numTentacles = $vmsWithTentacles.count
        $tentaclesRequired = $numWebServers + 1 
        $currentStatus = "$currentStatus Tentacles deployed: $numTentacles / $tentaclesRequired"
        Write-Output "        $currentStatus"
    }
    
    if ($allVmsConfigured){
        Write-Output "SUCCESS! Environment built successfully."
        break
    }
    if (($time -gt 1200) -and (-not $runningWarningGiven)){
        Write-Warning "EC2 instances are taking an unusually long time to start."
        $runningWarningGiven = $true
    }

    if (($time -gt $timeout)-and (-not $allVmsConfigured)){
        Write-Error "Timed out. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
    }   
    Start-Sleep -s 10
}