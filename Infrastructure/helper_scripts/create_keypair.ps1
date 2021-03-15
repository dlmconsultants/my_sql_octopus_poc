param(
    $keyPairName = "my_sql_octopus_poc",
    $keyPairDir = "C:\keypairs"
)

$ErrorActionPreference = "Stop"  

$newKeyPairRequired = $false

$date = Get-Date -Format "yyyy-MM-dd_HH-mm-ss_K" | ForEach-Object { $_ -replace ":", "." }
$keyPairPath = "$keyPairDir\$keyPairName.pem"

# Checking to see if the keypair already exists in EC2
try {
    Get-EC2KeyPair -KeyName $keyPairName | out-null
    Write-Output "    Keypair already exists in EC2."
    $newKeyPairRequired = $false
}
catch {
    Write-Output "    Keypair does not exist in EC2. Will attempt to create it."
    $newKeyPairRequired = $true
}

# If it's not already in EC2, we need to create it
if ($newKeyPairRequired){   
    try {
        # Create the new keypair
        Write-Output "    Creating keypair $keyPairName."
        New-EC2KeyPair -KeyName $keyPairName | out-null
    }
    catch {
        Write-Output "    Failed to create keypair $keyPairName. It's possible that another process has created it."
    }

    # Verify that the keypair now exists in EC2
    try {
        Get-EC2KeyPair -KeyName $keyPairName | out-null
        Write-Output "    Keypair $keyPairName now exists."
    }
    catch {
        Write-Warning "    Keypair $keyPairName does not exist."
    }
}
