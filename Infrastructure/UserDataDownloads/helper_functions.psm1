Function Update-StatupStatus {
    param (
        [Parameter(Mandatory=$true)]$status
    )
    $instanceMetaDataUri = "http://169.254.169.254/latest/meta-data/instance-id"
    $instanceId = Invoke-WebRequest -Uri $instanceMetaDataUri -TimeoutSec 1 -UseBasicParsing
  
    # Add new StartupStatus tag
    $tag = @( @{key="StartupStatus";value=$status} )
    New-EC2Tag -Resource $instanceId -Tag $tag # Actually replaces, if tag already exists
}

# updating the sa password
function get-secret(){
    param ($secret)
    $secretValue = Get-SECSecretValue -SecretId $secret
    # values are returned in format: {"key":"value"}
    $splitValue = $secretValue.SecretString -Split '"'
    $cleanedSecret = $splitValue[3]
    return $cleanedSecret
  }



