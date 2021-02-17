# Importing helper functions
Import-Module -Name "$PSScriptRoot\helper_functions.psm1" -Force

# Check the SecretsManager role exists before running this script
if (-not (Test-SecretsManagerRoleExists)){
    Write-Error "SecretsManager role does not exist. Verify that the SecretsManager role exists, then try running this script again."
}

# Test to see if SecretsManager role is already added to RandomQuotes profile...
if (Test-RoleAddedToProfile){
    Write-Output "    SecretsManager role is already added to RandomQuotes profile."
    # Our work here is done!
}

# Apparently SecretsManager role is not added to RandomQuotes profile, looks like we have work to do...
else {
    # If required, create a RandomQuotes profile...
    if (Test-RandomQuotesProfileExists){
        Write-Output "    RandomQuotes profile already exists."
    }
    else {
        Write-Output "    Creating RandomQuotes profile."
        try {
            New-IAMInstanceProfile -InstanceProfileName RandomQuotes | out-null
            Write-Output "      RandomQuotes profile created."
        }
        catch {
            if (Test-RandomQuotesProfileExists){
                Write-Output "      RandomQuotes profile created by a competing process."
            }
            else {
                Write-Warning "Failed to create RandomQuotes profile."
            }
        }
    }

    # Adding the SecretsManager role to the RandomQuotes profile
    Write-Output "    Adding SecretsManager role to RandomQuotes profile."
    try {
        Add-IAMRoleToInstanceProfile -InstanceProfileName RandomQuotes -RoleName SecretsManager
        Write-Output "      SecretsManager role added to RandomQuotes profile."
    }
    catch {
        if (Test-RoleAddedToProfile){
            Write-Output "      SecretsManager role added to RandomQuotes profile by a competing process."
        }
        else {
            Write-Warning "Failed to add SecretsManager role to RandomQuotes profile."
        }
    }
}

