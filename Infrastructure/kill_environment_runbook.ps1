param(
    $awsAccessKey = "",
    $awsSecretKey = "",
    $awsRegion = "" # Carbon neutral regions are listed here: https://aws.amazon.com/about-aws/sustainability/
)

$ErrorActionPreference = "Stop"  

# Setting default values for AWS access parameters
$missingParams = @()

if ($awsAccessKey -like ""){
    try {
        $awsAccessKey = $OctopusParameters["AWS_ACCOUNT.AccessKey"]
        Write-Output "Found value for awsAccessKey in Octopus variables." 
    }
    catch {
        Write-Warning "Did not find value for awsAccessKey from Octopus variables!" 
        $missingParams = $missingParams + "-awsAccessKey"
    }
}

if ($awsSecretKey -like ""){
    try {
        $awsSecretKey = $OctopusParameters["AWS_ACCOUNT.SecretKey"]
        Write-Output "Found value for awsSecretKey from Octopus variables." 
    }
    catch {
        Write-Warning "Did not find value for awsSecretKey in Octopus variables!" 
        $missingParams = $missingParams + "-awsSecretKey"
    }
}

$awsRegion = $OctopusParameters["AWS_REGION"]
if ($awsRegion -like ""){
    $awsRegion = "eu-west-1"
    Write-Output "AWS_REGION not set in octopus variables. Defaulting to: $awsRegion" 
}
else {
    Write-Output "Found value $awsRegion for AWS_REGION from Octopus variables." 
}

if ($missingParams.Count -gt 0){
    $errorMessage = "Missing the following parameters: "
    foreach ($param in $missingParams) {
        $errorMessage += "$param, "
    }
    Write-Error $errorMessage
}

Write-Output "  Execution root dir: $PSScriptRoot"
Write-Output "*"

# Install AWS tools
Write-Output "Executing .\helper_scripts\install_AWS_tools.ps1..."
Write-Output "  (No parameters)"
& $PSScriptRoot\helper_scripts\install_AWS_tools.ps1
Write-Output "*"

# Configure your default profile
Write-Output "Executing .\helper_scripts\configure_default_aws_profile.ps1..."
Write-Output "  Parameters: -AwsAccessKey $awsAccessKey -AwsSecretKey *** -AwsRegion $awsRegion"
& $PSScriptRoot\helper_scripts\configure_default_aws_profile.ps1 -awsAccessKey $awsAccessKey -awsSecretKey $awsSecretKey -awsRegion $awsRegion
Write-Output "*"

# Creates the VMs
Write-Output "Executing .\helper_scripts\kill_infra.ps1..."
Write-Output "  (No parameters)"
& $PSScriptRoot\helper_scripts\kill_infra.ps1 
Write-Output "*"
