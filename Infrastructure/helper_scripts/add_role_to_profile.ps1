# Importing helper functions
Import-Module -Name "$PSScriptRoot\helper_functions.psm1" -Force

# Check the SecretsManager role exists before running this script
if (-not (Test-SecretsManagerRoleExists)){
    Write-Error "SecretsManager role does not exist. Verify that the SecretsManager role exists, then try running this script again."
}

# Test to see if SecretsManager role is already added to my_sql_octopus_poc profile...
if (Test-RoleAddedToProfile -InstanceProfileName my_sql_octopus_poc -RoleName SecretsManager){
    Write-Output "    SecretsManager role is already added to my_sql_octopus_poc profile."
    # Our work here is done!
}

# Apparently SecretsManager role is not added to my_sql_octopus_poc profile, looks like we have work to do...
else {
    # If required, create a my_sql_octopus_poc profile...
    if (Test-ProfileExists -InstanceProfileName my_sql_octopus_poc){
        Write-Output "    my_sql_octopus_poc profile already exists."
    }
    else {
        Write-Output "    Creating my_sql_octopus_poc profile."
        try {
            New-IAMInstanceProfile -InstanceProfileName my_sql_octopus_poc | out-null
            Write-Output "      my_sql_octopus_poc profile created."
        }
        catch {
            if (Test-ProfileExists -InstanceProfileName my_sql_octopus_poc){
                Write-Output "      my_sql_octopus_poc profile created by a competing process."
            }
            else {
                Write-Warning "Failed to create my_sql_octopus_poc profile."
            }
        }
    }

    # Adding the SecretsManager role to the my_sql_octopus_poc profile
    Write-Output "    Adding SecretsManager role to my_sql_octopus_poc profile."
    try {
        Add-IAMRoleToInstanceProfile -InstanceProfileName my_sql_octopus_poc -RoleName SecretsManager
        Write-Output "      SecretsManager role added to my_sql_octopus_poc profile."
    }
    catch {
        if (Test-RoleAddedToProfile -InstanceProfileName my_sql_octopus_poc -RoleName SecretsManager){
            Write-Output "      SecretsManager role added to my_sql_octopus_poc profile by a competing process."
        }
        else {
            Write-Warning "Failed to add SecretsManager role to my_sql_octopus_poc profile."
        }
    }
}

