Function Update-StatupStatus {
    param (
        [Parameter(Mandatory=$true)]$status
    )
    $instanceMetaDataUri = "http://169.254.169.254/latest/meta-data/instance-id"
    $instanceId = Invoke-WebRequest -Uri $instanceMetaDataUri -TimeoutSec 1 -UseBasicParsing
  
    Import-Module -name AWS.Tools.EC2
    # Add new StartupStatus tag
    $tag = New-Object Amazon.EC2.Model.Tag
    $tag.Key = "StartupStatus"
    $tag.Value = $status
    New-EC2Tag -Resource $instanceId -Tag $tag # Actually replaces, if tag already exists
}






