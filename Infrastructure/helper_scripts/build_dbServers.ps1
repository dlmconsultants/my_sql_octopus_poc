param(
    $instanceType = "t2.micro", # 1 vCPU, 1GiB Mem, free tier elligible: https://aws.amazon.com/ec2/instance-types/
    $ami = "ami-0d2455a34bf134234", # Microsoft Windows Server 2019 Base with Containers
    $numWebServers = 1,
    $timeout = 4800 # seconds
)

$ErrorActionPreference = "Stop"
$stopwatch =  [system.diagnostics.stopwatch]::StartNew()

# Initialising variables
$rolePrefix= ""
try {
    $rolePrefix = $OctopusParameters["Octopus.Project.Name"]
}
catch {
    $rolePrefix = "UnknownProject"
}

$tagValue= ""
try {
    $tagValue = $OctopusParameters["Octopus.Environment.Name"]
}
catch {
    $tagValue = "EnvironmentUnknown"
}

$octoUrl= ""
try {
    $octoUrl = $OctopusParameters["Octopus.Web.BaseUrl"]
}
catch {
    $octoUrl = "OctopusUrlUnknown"
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
    $userData = $userData.replace("__ENV__",$octoEnv)
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
        $count = 1
    )
    $existingServers = Get-Servers -role $role -value $value -includePending
    $required = $count - $existingServers.count
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
Write-Output "Launching SQL Server"
Build-Servers -role $dbServerRole -encodedUserData $dbServerUserData 
Write-Output "Launching SQL Jumpbox"
Build-Servers -role $dbJumpboxRole -encodedUserData $jumpServerUserData
Write-Output "Launching Web Server(s)"
Build-Servers -role $webServerRole -encodedUserData $webServerUserData -count $numWebServers

# Checking all the instances
$dbServerInstances = Get-Servers -role $dbServerRole -includePending
$dbJumpboxInstances = Get-Servers -role $dbJumpboxRole -includePending
$webServerInstances = Get-Servers -role $webServerRole -includePending

# Logging all the instance details
Write-Output "    Verifying SQL Server instance: "
ForEach ($instance in $dbServerInstances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "      Instance $id is in state: $state"
}

Write-Output "    Verifying SQL Jumpbox instance: "
ForEach ($instance in $dbJumpboxInstances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "      Instance $id is in state: $state"
}

Write-Output "    Verifying Web Server instance(s): "
ForEach ($instance in $webServerInstances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "      Instance $id is in state: $state"
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
$vms = New-Object System.Data.Datatable
[void]$vms.Columns.Add("ip")
[void]$vms.Columns.Add("role")
[void]$vms.Columns.Add("sql_running")
[void]$vms.Columns.Add("sql_logins")
[void]$vms.Columns.Add("iis_running")
[void]$vms.Columns.Add("tentacle_listening")

While (-not $allRunning){
    
    $runningDbServerInstances = Get-Servers -role $dbServerRole
    $runningDbJumpboxInstances = Get-Servers -role $dbJumpboxRole
    $runningWebServerInstances = Get-Servers -role $webServerRole

    $allInstances = @()
    $allInstances += $runningDbServerInstances 
    $allInstances += $runningDbJumpboxInstances 
    $allInstances += $runningWebServerInstances 

    $NumRunning = $allInstances.count

    if ($NumRunning -eq ($numWebServers + 2)){
        $allRunning = $true
        
        # Logging all the IP addresses
        Write-Output "      All instances are running!"
        ForEach ($instance in $runningInstances){
            $id = $instance.InstanceId
            $ipAddress = $instance.PublicIpAddress
            Write-Output "        Instance $id is available at the public IP: $ipAddress"
        }

        # Populating our table of VMs
        ForEach ($instance in $dbServerInstances){
            [void]$vms.Rows.Add($instance.PublicIpAddress,$dbServerRole,$false,$false,$null,$null)
        }
        ForEach ($instance in $dbJumpboxInstances){
            [void]$vms.Rows.Add($instance.PublicIpAddress,$dbJumpboxRole,$null,$null,$null,$false)
        }
        ForEach ($instance in $webServerInstances){
            [void]$vms.Rows.Add($instance.PublicIpAddress,$webServerRole,$null,$null,$false,$false)
        }
        break
    }
    else {
        Write-Output "      $NumRunning out of $numWebServers instances are running."
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

Write-Output "      $time seconds | Waiting for instances to become responsive... (This normally takes about 5 minutes.)"

# Helper functions to ping the instances
function Test-SQL {
    param (
        $ip,
        $cred
    )
    try { 
        Invoke-DbaQuery -SqlInstance $ip -Query 'SELECT @@version' -SqlCredential $cred -EnableException
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

function Get-Tentacles {
    param (
        $role
    )
    Write-output "Role: $role"
    Write-Warning "TO DO: Write a Get-Tentacles function!"
}

# Waiting to see if they all come online
$allVmsConfigured = $false
$runningWarningGiven = $false

Write-Warning "Remove the hardcoded passwords!"
$saUsername = "sa"
try {
    $saPassword = $OctopusParameters["sqlSaPassword"] | ConvertTo-SecureString -AsPlainText -Force
}
catch {
    $saPassword = "S4fePa55word!!!" | ConvertTo-SecureString -AsPlainText -Force
}
$saCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $saUsername, $saPassword

$octoUsername = "octopus"
try {
    $octoPassword = $OctopusParameters["sqlOctopusPassword"] | ConvertTo-SecureString -AsPlainText -Force
}
catch {
    $octoPassword = "5re4lsoRocks" | ConvertTo-SecureString -AsPlainText -Force
}
$octoCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $octoUsername, $octoPassword

While (-not $allVmsConfigured){
 

    # Checking whether anything new has come online
    ## SQL Server
    $pendingSqlVms = $vms.Select("sql_running like '$false'")
    forEach ($ip in $pendingSqlVms.ip){
        $sqlDeployed = Test-SQL -ip $ip -cred $saCred
        if ($sqlDeployed){
            Write-Output "    SQL Server is running on: $ip"
            $thisVm = $vms.Select("ip like '$ip'")
            $thisVm.sql_running = $true
        }
    }
    
    ## SQL Logins
    $pendingSqlLogins = $vms.Select("sql_logins like '$false'")
    forEach ($ip in $pendingSqlLogins.ip){
        $loginsDeployed = Test-SQL -ip $ip -cred $octoCred
        if ($loginsDeployed){
            Write-Output "    SQL Server Logins deployed to: $ip"
            $thisVm = $vms.Select("ip like '$ip'")
            $thisVm.sql_logins = $true
        }
    }

    ## IIS
    $pendingIisInstalls = $vms.Select("iis_running like '$false'")
    forEach ($ip in $pendingIisInstalls.ip){
        $iisDeployed = Test-IIS -ip $ip
        if ($iisDeployed){
            Write-Output "    IIS is running on: $ip"
            $thisVm = $vms.Select("ip like '$ip'")
            $thisVm.iis_running = $true
        }
    }

    ## Tentacles
    $pendingTentacles = $vms.Select("tentacle_listening like '$false'")
    forEach ($ip in $pendingTentacles.ip){
        $tentacleDeployed = Test-IIS -ip $ip
        if ($tentacleDeployed){
            Write-Output "    Octopus Tentacle is listening on: $ip"
            $thisVm = $vms.Select("ip like '$ip'")
            $thisVm.tentacle_listening = $true
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
        Write-Output "    Waiting for all machines to come online."
    }
    
    if ($allVmsConfigured){
        Write-Output "SUCCESS! Environment built successfully."
        break
    }
    if (($time -gt 600) -and (-not $runningWarningGiven)){
        Write-Warning "EC2 instances are taking an unusually long time to start."
        $runningWarningGiven = $true
    }

    if (($time -gt $timeout)-and (-not $allVmsConfigured)){
        Write-Error "Timed out. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
    }   
    Start-Sleep -s 10
}