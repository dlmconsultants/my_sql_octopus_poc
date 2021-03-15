param(
    $securityGroupName = "my_sql_octopus_poc"
)

$ErrorActionPreference = "Stop"  

# Importing helper functions
Import-Module -Name "$PSScriptRoot\helper_functions.psm1" -Force

# Create the SecurityGroup (if it does not already exist)
if (Test-SecurityGroup -groupName $securityGroupName){
    Write-Output "    SecurityGroup $securityGroupName already exists."
}
else {
    # Creates a new security group
    Write-Output "    Creating security group $securityGroupName."
    try {
        $securityGroup = New-EC2SecurityGroup -GroupName $securityGroupName -Description "Accepts Web, RDP and Octopus traffic from any IP address."

        # Tags the security group
        $Tag = New-Object Amazon.EC2.Model.Tag
        $Tag.Key = "my_sql_octopus_poc"
        $Tag.Value = ""
        New-EC2Tag -Resource $securityGroup -Tag $Tag

        Write-Output "      SecurityGroup $securityGroupName created."
    }
    catch {
        if (Test-SecurityGroup -groupName $securityGroupName){
            Write-Output "      SecurityGroup $securityGroupName created by a competing process."
        }
        else {
            Write-Warning "      Failed to create SecurityGroup: $securityGroupName."
        }
    }
}

# Create the SecurityGroup (if it does not already exist)
$requiredPorts = @(80, 1433, 3389, 10933)
if (Test-SecurityGroupPorts -groupName $securityGroupName -requiredPorts $requiredPorts){
    Write-Output "    SecurityGroup $securityGroupName is already open on ports $requiredPorts."
} 
else {
    Write-Output "    Opening ports $requiredPorts on SecurityGroup $securityGroupName."
    try {  
        $ip1 = @{ IpProtocol="tcp"; FromPort="80"; ToPort="80"; IpRanges="0.0.0.0/0" } # Website hosting
        $ip2 = @{ IpProtocol="tcp"; FromPort="1433"; ToPort="1433"; IpRanges="0.0.0.0/0" } # SQL Server
        $ip3 = @{ IpProtocol="tcp"; FromPort="3389"; ToPort="3389"; IpRanges="0.0.0.0/0" } # Remote Desktop
        $ip4 = @{ IpProtocol="tcp"; FromPort="10933"; ToPort="10933"; IpRanges="0.0.0.0/0" } # Octopus Deploy
        Grant-EC2SecurityGroupIngress -GroupName $securityGroupName -IpPermission @($ip1, $ip2, $ip3, $ip4)
        Write-Output "      Ports opened."
    }
    catch {
        if (Test-SecurityGroupPorts -groupName $securityGroupName -requiredPorts $requiredPorts){
            Write-Output "      Ports already opened by a competing process."
        } 
        else {
            Write-Warning "Failed to open the necessary ports on SecurityGroup $securityGroupName."
        }
    }
}
