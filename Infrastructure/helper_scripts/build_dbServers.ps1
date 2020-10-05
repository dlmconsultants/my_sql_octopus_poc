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

$acceptableStates = @("pending", "running")

$dbIpAddress = ""

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

# Helper function to check if server already exists
Function Test-Server {
    param (
        $role,
        $value = $tagValue
    )
    $instances = (Get-EC2Instance -Filter @{Name="tag:$role";Values=$value}, @{Name="instance-state-name";Values=$acceptableStates}).Instances 
    if ($instances.count -eq 0){
        return $true
    }
    return $false
}

# Helper function to build a server if it doesn't already exist
Function Build-Server {
    param (
        $role,
        $value = $tagValue,
        $encodedUserData,
        $count = 1
    )
    if (Test-Server $dbServerRole){
        $NewInstance = New-EC2Instance -ImageId $ami -MinCount $count -MaxCount 1 -InstanceType $instanceType -UserData $encodedUserData -KeyName RandomQuotes_SQL -SecurityGroup RandomQuotes_SQL -IamInstanceProfile_Name RandomQuotes_SQL
        # Tagging all the instances
        ForEach ($InstanceID  in ($NewInstance.Instances).InstanceId){
            New-EC2Tag -Resources $( $InstanceID ) -Tags @(
                @{ Key=$role; Value=$value}
            );
        }
    }    
}

# Building all the servers
Build-Server -role $dbServerRole -encodedUserData $dbServerUserData
Build-Server -role $dbJumpboxRole -encodedUserData $jumpServerUserData
Build-Server -role $webServerRole -encodedUserData $webServerUserData -count $numWebServers

# Checking all the instances
$dbServerInstances = (Get-EC2Instance -Filter @{Name="tag:$dbServerRole";Values=$tagValue}, @{Name="instance-state-name";Values=$acceptableStates}).Instances
$dbJumpboxInstances = (Get-EC2Instance -Filter @{Name="tag:$dbJumpboxRole";Values=$tagValue}, @{Name="instance-state-name";Values=$acceptableStates}).Instances
$webServerInstances = (Get-EC2Instance -Filter @{Name="tag:$webServerRole";Values=$tagValue}, @{Name="instance-state-name";Values=$acceptableStates}).Instances

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

Write-Output "      $time seconds | Waiting for instances to start... (This normally takes about 30 seconds.)"

$allRunning = $false
While (-not $allRunning){
    
    $dbServerInstances = (Get-EC2Instance -Filter @{Name="tag:$dbServerRole";Values=$tagValue}, @{Name="instance-state-name";Values="running"}).Instances
    $dbJumpboxInstances = (Get-EC2Instance -Filter @{Name="tag:$dbJumpboxRole";Values=$tagValue}, @{Name="instance-state-name";Values="running"}).Instances
    $webServerInstances = (Get-EC2Instance -Filter @{Name="tag:$webServerRole";Values=$tagValue}, @{Name="instance-state-name";Values="running"}).Instances
    
    $allInstances = @()
    $allInstances += $dbServerInstances 
    $allInstances += $dbJumpboxInstances 
    $allInstances += $webServerInstances 

    $NumRunning = $allInstances.count
    
    $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))

    if ($NumRunning -eq ($numWebServers + 2)){
        $allRunning = $true
        Write-Output "      $time seconds | All instances are running!"
        $dbIpAddress = $dbServerInstances[0].PublicIpAddress
        ForEach ($instance in $runningInstances){
            $id = $instance.InstanceId
            $ipAddress = $instance.PublicIpAddress
            Write-Output "        Instance $id is available at the public IP: $ipAddress"
        }
        break
    }
    else {
        Write-Output "      $time seconds | $NumRunning out of $numWebServers instances are running."
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
        $cred
    )
    try { 
        Invoke-DbaQuery -SqlInstance $dbIpAddress -Query 'SELECT @@version' -SqlCredential $cred -EnableException
    }
    catch {
        return $false
    }
    return $true
}

function Test-IIS {
    Write-Warning "TO DO: Write a Test-IIS function!"
}

function Get-Tentacles {
    param (
        $role
    )
    Write-output "Role: $role"
    Write-Warning "TO DO: Write a Get-Tentacles function!"
}

Write-Warning "Consider creating a hashtable or something for all websevers to keep track of IIS/tentacles etc"

# Waiting to see if they all come online
$allListening = $false
$runningWarningGiven = $false
$SqlOnline = $false
$LoginsDeployed = $false
$JumpboxListening = $false
$IssInstalls = 0
$WebServersListening = 0

$saPassword = $OctopusParameters["sqlSaPassword"] | ConvertTo-SecureString -AsPlainText -Force
$saUsername = "sa"
$saCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $saUsername, $saPassword

$octoUsername = "octopus"
$octoPassword = $OctopusParameters["sqlOctopusPassword"] | ConvertTo-SecureString -AsPlainText -Force
$octoCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $octoUsername, $octoPassword

While (-not $allListening){
    if (-not $SqlOnline){
        $SqlOnline = Test-SQL -cred $saCred
    }
    if (-not $LoginsDeployed){
        $LoginsDeployed = Test-SQL -cred $octoCred
    }
    if (-not $JumpboxListening){
        $jumpboxes = Get-Tentacles -role $dbJumpboxRole
        if ($jumpboxes.count = 1){
            $JumpboxListening = $true
        }
    }
    if ($IssInstalls -lt $numWebServers){
        Write-Warning "To do: Figute out how to check IIS on all the web servers!"
    }
    if ($WebServersListening -lt $numWebServers){
        $webServers = Get-Tentacles -role $webServerRole
        if ($webServers.count -gt $WebServersListening){
            Write-Warning "To do: Log which web server just came online!"
            $WebServersListening = $webServers.count
        }
    }


    $time = $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
    Write-Output "$time seconds | SQL- Installed: $SqlOnline, Logins: $LoginsDeployed, Jumpbox: $JumpboxListening | WEB- IIS: $IssInstalls, Tentacles: $WebServersListening"
                 #Extracting package 'C:\Octopus\Tentacle\Files\RandomQuotes_SQL_infra@S0.0.53@7F26AF5DA0AB8B4FB2F4A449E5F141C3.nupkg' to 
    if (($time -gt 60) -and (-not $runningWarningGiven)){
        Write-Warning "EC2 instances are taking an unusually long time to start."
        $runningWarningGiven = $true
    }
    if ($time -gt $timeout){
        Write-Error "Timed out at $time seconds. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
    }    
    
    if (( $LoginsDeployed -and $JumpboxListening) -and ($WebServersListening -eq $WebServersListening)){
        $allListening = $true
        Write-Output "SUCCESS! Environment built successfully. SQL Server IP address is: $dbIpAddress"
        break
    }
    Start-Sleep -s 15
}