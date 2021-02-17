<#
Installs the latest version of the necessary AWS PowerShell modules.

This script is annoyingly complicated to avoid race conditions.
If two runbooks try to install a module at the same time, you run into all sorts of pain.
In development I hit this issue quite often. For example, whenever I tried to build/delete both a Dev and Prod environment at the same time.

To avoid problems, this script saves a "holding file" whenever it tries to install anything.
Each holding file contains the RunbookRunId of the runbook run that created it.
Other runbooks can check these holding files to avoid two runbooks attempting to install the same module simultaneously.

To keep this simple, I've extracted a few helper functions to \Infrastructure\helper_scripts\helper_functions.psm1:
- New-HoldFile
- Test-HoldFile
- Remove-HoldFile
- Test-ModuleInstalled
- Install-ModuleWithHoldFile
#>

######################################################
###                     CONFIG                     ###
######################################################

$ErrorActionPreference = "Stop"  

# Importing helper functions
Import-Module -Name "$PSScriptRoot\helper_functions.psm1" -Force

# The modules we need
$requiredModules = @(
    "AWS.Tools.Common",
    "AWS.Tools.EC2",
    "AWS.Tools.IdentityManagement",
    "AWS.Tools.SimpleSystemsManagement",
    "AWS.Tools.SecretsManager"
)
$installedModules = @()

######################################################
###                INSTALL MODULES                 ###
######################################################

Write-Output "    Installing modules."
foreach ($module in $requiredModules){
    $moduleAlreadyInstalled = Test-ModuleInstalled -moduleName $module
    if ($moduleAlreadyInstalled){
        Write-Output "      Module $module is already installed."
        $installedModules += $module
    }
    else {
        $holdingProcess = Test-HoldFile -holdFileName $module
        if ($holdingProcess){
            Write-Output "      Module $module is being installed by $holdingProcess"
        } 
        else {
            Write-Output "      Installing $module."
            Install-ModuleWithHoldFile -moduleName $module | out-null
            if (Test-ModuleInstalled -moduleName $module){
                Write-Output "        $module has been installed successfully."
                $installedModules += $module
            }
        }
    }
}

######################################################
###          HOLD FOR COMPETING PROCESSES          ###
######################################################

if ($installedModules.length -lt $requiredModules.length) {
    Write-Output "    Waiting for all modules to finish installing."
        
    # A little config for holding loop
    $time = 0
    $timeout = 100
    $pollFrequency = 5
    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

    # Waiting in a holding loop until all modules are installed
    while ($installedModules.length -lt $requiredModules.length){
        $remainingModules = $requiredModules | Where-Object {$_ -notin $installedModules}
        foreach ($module in $remainingModules){
            if (Test-ModuleInstalled -moduleName $module){
                $installedModules += $module
            }
        }

        # Logging progress
        $numInstalled = $installedModules.length
        $numRequired = $requiredModules.length
        if ($numInstalled -eq $numRequired){
            break
        }
        Write-Output    "      $time/$timeout seconds: $numInstalled/$numRequired modules installed."

        # Wait a bit, then try again
        $time = [Math]::Floor([decimal]($stopwatch.Elapsed.TotalSeconds))
        if ($time -gt $timeout){
            Write-Warning "This is taking an unusually long time."
            break
        }
        Start-Sleep $pollFrequency
    }
}

# If there are any hold files left, delete them
# By now, any other process should have had plenty of time to install the module
# If it failed, but it did not clean up the hold file, that's likely to cause problems

Remove-AllHoldFiles

######################################################
###          CHECK ALL MODULES INSTALLED           ###
######################################################          

$successfulInstalls = @()
$failedInstalls = @()
foreach ($module in $requiredModules){
    $moduleInstalled = Test-ModuleInstalled -moduleName $module
    if ($moduleInstalled){
        $successfulInstalls += $module
    }
    else {
        $failedInstalls += $module
    }
}

$diff = Compare-Object -ReferenceObject $requiredModules -DifferenceObject $successfulInstalls 

if ($diff){
    $errorMsg = "FAILED TO INSTALL: $failedInstalls"
    Write-Error $ErrorMsg
}
else {
    Write-Output "    All modules installed successfully."
}