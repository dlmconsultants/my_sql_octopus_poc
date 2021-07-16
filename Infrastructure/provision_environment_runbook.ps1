param(
    $awsAccessKey = "",
    $awsSecretKey = "",
    $defaulAwsRegion = "", # Carbon neutral regions are listed here: https://aws.amazon.com/about-aws/sustainability/
    $securityGroupName = "my_sql_octopus_poc",
    $numWebServers = 1,
    $instanceType = "t2.micro", # 1 vCPU, 1GiB Mem, free tier elligible: https://aws.amazon.com/ec2/instance-types/
    $tagValue = "Created manually",
    $octoUrl = "",
    $octoEnv = "",
    [Switch]$DeployTentacle,
    [Switch]$DeployDbServer,
    [Switch]$DeployWebServers
)

$ErrorActionPreference = "Stop"  

Write-Output "*"
Write-Output "Setup..."
Write-Output "*"

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

if ($defaulAwsRegion -like ""){
    try {
        $defaulAwsRegion = $OctopusParameters["AWS_REGION"]
        Write-Output "Found value $defaulAwsRegion for DEFAULT_AWS_REGION from Octopus variables." 
    }
    catch {
        $defaulAwsRegion = "eu-west-1"
        Write-Output "Did not find value for DEFAULT_AWS_REGION in Octopus variables. Defaulting to $defaulAwsRegion." 
        
    }
    if ($defaulAwsRegion -like ""){
        Write-Warning "Something failed while setting the default AWS region."
        $missingParams = $missingParams + "-awsSecretKey"
    }
}

if ($missingParams.Count -gt 0){
    $errorMessage = "Missing the following parameters: "
    foreach ($param in $missingParams) {
        $errorMessage += "$param, "
    }
    Write-Error $errorMessage
}

# If (this script it executed by Octopus AND $DeployTentacle is true):
# Updating default values for octoEnv, octoUrl and tagValue
if ($DeployTentacle){
    try {
        if ($octoUrl -like ""){
            $msg = "Octopus URL detected: " + $OctopusParameters["Octopus.Web.ServerUri"]
            Write-Output $msg
            $octoUrl = $OctopusParameters["Octopus.Web.ServerUri"]
        }
    }
    catch {
        if ($DeployTentacle){
            $DeployTentacle = $false
            Write-Warning "No Octopus URL detected. Cannot deploy the Tentacle"
        }
    }
}

try {
    if ($octoEnv -like ""){
        $msg = "Octopus Environment detected: " + $OctopusParameters["Octopus.Environment.Name"]
        Write-Output $msg
        $octoEnv = $OctopusParameters["Octopus.Environment.Name"]
    }
}
catch {
    $DeployTentacle = $false
    Write-Warning "No Octopus Environment detected. Cannot deploy the Tentacle"
}

# If no default tag has been provided, but we do have an octoEnv, set tagValue to octoEnv
if (($tagValue -like "Created manually") -and ($OctoEnv -notlike "") ){
    $tagValue = $octoEnv
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
Write-Output "  Parameters: -AwsAccessKey $awsAccessKey -AwsSecretKey *** -DefaulAwsRegion $defaulAwsRegion"
& $PSScriptRoot\helper_scripts\configure_default_aws_profile.ps1 -AwsAccessKey $awsAccessKey -AwsSecretKey $awsSecretKey -DefaulAwsRegion $defaulAwsRegion
Write-Output "*"

# Create Keypair
Write-Output "Executing .\helper_scripts\create_aws_role.ps1..."
Write-Output "  (No parameters)"
& $PSScriptRoot\helper_scripts\create_aws_role.ps1
Write-Output "*"

# Create AWS Role
Write-Output "Executing .\helper_scripts\create_keypair.ps1..."
Write-Output "  (No parameters)"
& $PSScriptRoot\helper_scripts\create_keypair.ps1
Write-Output "*"

# Creates a RandomQuotes profile containing the SecretsManager role for all VMs
# This allows the VMs to access secrets manager, which allows us to avoid hardcoding passwords into sourcecode/the userdata file
Write-Output "Executing .\helper_scripts\add_role_to_profile.ps1..."
Write-Output "  (No parameters)"
& $PSScriptRoot\helper_scripts\add_role_to_profile.ps1
Write-Output "*"

# Creates a security group in AWS to allow RDP sessions on all your demo VMs
Write-Output "Executing .\helper_scripts\create_security_group.ps1..."
Write-Output "  Parameters: -securityGroupName $securityGroupName"
& $PSScriptRoot\helper_scripts\create_security_group.ps1 -securityGroupName $securityGroupName
Write-Output "*"

# Deploys all the VMs
Write-Output "Executing .\helper_scripts\build_servers.ps1..."
Write-Output "  Parameters: -numWebServers $numWebServers"
& $PSScriptRoot\helper_scripts\build_servers.ps1 -numWebServers $numWebServers
Write-Output "*"
