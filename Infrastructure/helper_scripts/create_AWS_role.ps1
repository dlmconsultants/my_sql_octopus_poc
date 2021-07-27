$ErrorActionPreference = "Stop"  
$roleName = "SecretsManager"
$policy = "$PSScriptRoot\IAM_SecretsManager_Policy.json"
Write-Output "    Access control policy is saved at: $policy"
# Policy ARN is: arn:aws:iam::aws:policy/SecretsManagerReadWrite
# More info: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_identifiers.html

# Importing helper functions
Import-Module -Name "$PSScriptRoot\helper_functions.psm1" -Force

# Create the role (if it does not already exist)
if (Test-SecretsManagerRoleExists) {
    Write-Output "    Role $roleName already exists."
} 
else {
    Write-Output "    Creating role $roleName with access control policy saved at: $policy"
    try {
        New-IAMRole -AssumeRolePolicyDocument (Get-Content -raw $policy) -RoleName $roleName -Tag @{ Key="Project"; Value="my_sql_octopus_poc"} | out-null
    }
    catch {
        if (Test-SecretsManagerRoleExists){
            Write-Output "      Role $roleName has already been created by another process."
        }
        else {
            Write-Error "Failed to create role: $roleName"
        }
    }
}

# This bit is re-runnable, so no need for a try catch etc
Write-Output "    Registering $roleName with policy SecretsManagerReadWrite"
Register-IAMRolePolicy -RoleName $roleName -PolicyArn arn:aws:iam::aws:policy/SecretsManagerReadWrite

# This is an ugly hack. I should add the tagging stuff to a different role.
Write-Output "    Registering $roleName with policy AmazonEC2SpotFleetTaggingRole"
Register-IAMRolePolicy -RoleName $roleName -PolicyArn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole