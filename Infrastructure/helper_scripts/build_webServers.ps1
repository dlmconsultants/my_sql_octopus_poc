param(
    $count = 1,
    $instanceType = "t2.micro", # 1 vCPU, 1GiB Mem, free tier elligible: https://aws.amazon.com/ec2/instance-types/
    $ami = "ami-0d2455a34bf134234", # Microsoft Windows Server 2019 Base with Containers
    $webServerRole = "my_sql_octopus_poc-WebServer",
    $tagValue = "Created manually",
    $octoUrl = "",
    $octoEnv = "",
    [Switch]$DeployTentacle,
    [Switch]$Wait,
    $timeout = 1200 # seconds
)

$ErrorActionPreference = "Stop"

# Reading VM_UserData
$userDataFile = "VM_UserData.ps1"
$userDataPath = "$PSScriptRoot\$userDataFile"
$userData = Get-Content -Path $userDataPath -Raw

# Preparing startup script for VM
if ($DeployTentacle){
    # If deploying tentacle, uncomment the deploy tentacle script
    $userData = $userData.replace("<# DEPLOY TENTACLE"," ")
    $userData = $userData.replace("DEPLOY TENTACLE #>"," ")
    # And substitute the octopus URL and environment
    $userData = $userData.replace("__OCTOPUSURL__",$octoUrl)
    $userData = $userData.replace("__ENV__",$octoEnv)
    $userData = $userData.replace("__ROLE__",$webServerRole)
}

if (Test-Path $userDataPath){
    Write-Output "    Reading UserData (VM startup script) from $userDataPath."
}
else {
    Write-Error "No UserData (VM startup script) found at $userDataPath!"
}
# Base 64 encoding the setup script. More info here: 
# https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2-windows-user-data.html
Write-Output "    Base 64 encoding UserData."
$encodedUserData = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($userData))

# Checking how many instances are already running
Write-Output "    Checking how many instances are already running with tag $webServerRole and value $tagValue..."
$acceptableStates = @("pending", "running")
$PreExistingInstances = (Get-EC2Instance -Filter @{Name="tag:$webServerRole";Values=$tagValue}, @{Name="instance-state-name";Values=$acceptableStates}).Instances 
$before = $PreExistingInstances.count
Write-Output "      $before instances are already running." 
$totalRequired = $count - $PreExistingInstances.count
if ($totalRequired -lt 0){
    $totalRequired = 0
}
Write-Output "      $totalRequired more instances required." 

if ($totalRequired -gt 0){
    Write-Output "    Launching $totalRequired instances of type $instanceType and ami $ami."
    

    Write-Output "      Instances will each have tag $webServerRole with value $tagValue."

    $NewInstance = New-EC2Instance -ImageId $ami -MinCount $totalRequired -MaxCount $totalRequired -InstanceType $instanceType -UserData $encodedUserData -KeyName my_sql_octopus_poc -SecurityGroup my_sql_octopus_poc -IamInstanceProfile_Name my_sql_octopus_poc

    # Tagging all the instances
    ForEach ($InstanceID  in ($NewInstance.Instances).InstanceId){
        New-EC2Tag -Resources $( $InstanceID ) -Tags @(
            @{ Key=$webServerRole; Value=$tagValue}
        );
    }
}
# Initializing potential error data
$oops = $false
$err = "There is a problem with the following instances: "

# Checking if it worked
Write-Output "    Verifying that all instances have been/are being created: "
$instances = (Get-EC2Instance -Filter @{Name="tag:$webServerRole";Values=$tagValue}, @{Name="instance-state-name";Values=$acceptableStates}).Instances

ForEach ($instance in $instances){
    $id = $instance.InstanceId
    $state = $instance.State.Name
    Write-Output "      Instance $id is in state: $state"
}

if ($instances.count -ne $count){
    $errmsg = "Expected to see $count instances, but actually see " + $instances.count + " instances."
    Write-Warning "$errmsg"
    $err = $err + ". Also, $errmsg"
    $oops = $true
}

# Logging results
if ($oops){
    Write-Error $err
} else {
    $msg = "    " + $instances.count + " instances have been launched successfully."
    Write-Output $msg
}

if ($Wait -and ($totalRequired -gt 0)){
    $allRunning = $false
    $allRegistered = $false
    $runningWarningGiven = $false
    $registeredWarningGiven = $false
    $ipAddresses = @()

    Write-Output "    Waiting for instances to start. (This normally takes about 30 seconds.)"
    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()
    
    While (-not $allRunning){
        $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
        
        if ($time -gt $timeout){
            Write-Error "Timed out at $time seconds. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
        }
        
        if (($time -gt 60) -and (-not $runningWarningGiven)){
            Write-Warning "EC2 instances are taking an unusually long time to start."
            $runningWarningGiven = $true
        }
        
        $runningInstances = (Get-EC2Instance -Filter @{Name="tag:$webServerRole";Values=$tagValue}, @{Name="instance-state-name";Values="running"}).Instances
        $NumRunning = $runningInstances.count
        
        if ($NumRunning -eq $count){
            $allRunning = $true
            Write-Output "      $time seconds: All instances are running!"
            ForEach ($instance in $runningInstances){
                $id = $instance.InstanceId
                $ip = $instance.PublicIpAddress
                $ipAddresses += $ip
                Write-Output "        Instance $id is available at the public IP: $ip"
            }
            break
        }
        else {
            Write-Output "      $time seconds: $NumRunning out of $count instances are running."
        }

        Start-Sleep -s 10
    }
    
    # Authenticating to the API
    try {
        $APIKey = $OctopusParameters["API_KEY"]
        $header = @{ "X-Octopus-ApiKey" = $APIKey }
    }
    catch {
        Write-Warning 'Failed to read the Octopus API Key from $OctopusParameters["API_KEY"].'
    }

    # Updating calimari on all tentacles
    function Update-Calimari {
        param (
            [Parameter(Mandatory=$true)][string]$MachineId,
            [Parameter(Mandatory=$true)][string]$MachineName
        )
        $body = @{ 
            Name = "UpdateCalamari" 
            Description = "Updating calamari on $MachineName" 
            Arguments = @{ 
                Timeout= "00:05:00" 
                MachineIds = @($MachineId) #$MachineId could contain an array of machines too
            } 
        } | ConvertTo-Json
        
        Invoke-RestMethod $octoUrl/api/tasks -Method Post -Body $body -Headers $header | out-null
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

    if ($deployTentacle){
        $machineNames = @()
        $machinesRunningIIS = @()
    
        Write-Output "    Waiting for tentacles to register with Octopus Server."
        Write-Output "    (It normally takes 3-5 minutes to set up IIS and 7-10 minutes to register tentacles.)"
        $stopwatch.Restart()

        While (-not $allRegistered){
            # Seeing how long we've been waiting so far
            $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
            
            # Checking the progress with IIS
            $newMachineOnline = $false
            forEach ($ip in $ipAddresses){
                $iisRunning = $false
                if ($ip -notIn $machinesRunningIIS){
                    $iisRunning = Test-IIS -ip $ip
                }
                if ($iisRunning){
                    $machinesRunningIIS += $ip
                    Write-Output "        Default IIS site is now available at $ip"
                    $newMachineOnline = $true
                }
            }

            # Calling the API to find get machine data
            $envID = $OctopusParameters["Octopus.Environment.Id"]
            $environment = (Invoke-WebRequest "$octoUrl/api/environments/$envID" -Headers $header -UseBasicParsing).content | ConvertFrom-Json
            $environmentMachines = $Environment.Links.Machines.Split("{")[0]
            $machines = ((Invoke-WebRequest ($octoUrl + $environmentMachines) -Headers $header -UseBasicParsing).content | ConvertFrom-Json).items
            $MachinesInRole = @()
            $MachinesInRole += $machines | Where-Object {$webServerRole -in $_.Roles}
            
            # If we've found a new machine, logging the details
            $NumRegistered = $MachinesInRole.Count
            $newlyRegisteredMachines = @()
            if ($NumRegistered -gt $machineNames.Count){
                ForEach ($m in $MachinesInRole){
                    if ($m.Name -notin $machineNames){
                        $name = $m.Name
                        $uri = $m.URI
                        $id = $m.Id
                        Write-Output "        Machine $name registered with URI $uri"
                        $machine = @{ id = $id; name = $name}
                        $newlyRegisteredMachines += $machine
                        $machineNames += $name
                    }
                }
            }
            # If we've found any new machines, updating Calimari on each
            if ($newlyRegisteredMachines.Count -gt 0){
                $updateCalimariMsg = "          Updating Calimari on the following machines:"
                foreach ($machine in $newlyRegisteredMachines){
                    $name = $machine.name
                    $updateCalimariMsg += " $name,"
                }
                Write-Output $updateCalimariMsg
                foreach ($machine in $newlyRegisteredMachines){
                    $id = $machine.id
                    $name = $machine.name
                    Update-Calimari -MachineID $id -MachineName $name
                }
            }
        
            # If we have all the machines we ordered, break out of the loop
            if ($NumRegistered -ge $count){
                $allRegistered = $true
                Write-Output "      $time seconds: $NumRegistered out of $count instances are registered."
                Write-Output "    SUCCESS! All $count machines are registered!"
                break
            }
            else {
                $IISCount = $machinesRunningIIS.Count
                Write-Output "      $time seconds: $IISCount IIS installs and $NumRegistered tentacles registered out of $count."
            }

            # If we've been waiting an oddly long amount of time, raise a warning
            if (($time -gt 600) -and (-not $registeredWarningGiven)){
                Write-Warning "Machines are taking an unusually long time to register."
                $registeredWarningGiven = $true
            }

            # If we've been waiting too long, time out
            if ($time -gt $timeout){
                Write-Error "Timed out at $time seconds. Timeout currently set to $timeout seconds. There is a parameter on this script to adjust the default timeout."
            }
            
            # Seems we don't yet have all of our machines: Let's wait 30s and try again
            Start-Sleep -s 30
        }
    }
}
