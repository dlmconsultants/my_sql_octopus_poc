param(
    $keyPairName = "my_sql_octopus_poc",
    $keyPairDir = "C:\keypairs"
)

$ErrorActionPreference = "Stop"  

$keyPairExists = $false
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
    # We need to create a new keypair
    if (Test-Path $keyPairPath){
        # Keypair deleted in EC2, but a private key is hanging around on the local machine.
        # It can probably be deleted, but just to be safe we'll archive it instead.
        Write-Warning "Stale keypair exists at: $keyPairPath"

        $archiveDir = "$keyPairDir\archive"
        $archivedKeyPairName = "$keyPairName-archived_at_$date.pem"
        $archiveFile = "$archiveDir\$archivedKeyPairName"

        Write-Output "    Archiving private key for keypair $keyPairName to: $archiveFile"
        Rename-Item -Path $keyPairPath -NewName $archivedKeyPairName
        if (-not (Test-Path $archiveDir)){
            New-Item -ItemType "directory" -Path $archiveDir
        }
        Move-Item -Path "$keyPairDir\$archivedKeyPairName" -Destination $archiveFile | out-null
    } 
    
    # Creating the new keypair
    Write-Output "    Creating keypair $keyPairName and saving private key to $keyPairPath"
    (New-EC2KeyPair -KeyName $keyPairName).KeyMaterial | Out-File -Encoding ascii -FilePath $keyPairPath
}