param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]$awsAccessKey,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]$awsSecretKey,
    $defaulAwsRegion = "eu-west-1" # Other carbon neutral regions are listed here: https://aws.amazon.com/about-aws/sustainability/
)

$ErrorActionPreference = "Stop"  

Write-Output "    Setting the AWS access and secret keys. Also setting the default region to $defaulAwsRegion."
Initialize-AWSDefaultConfiguration -AccessKey $awsAccessKey -SecretKey $awsSecretKey -Region $defaulAwsRegion 

try {
    Write-Output "    Attempting to connect to EC2."
    $instances = Get-EC2Instance
    Write-Output "    Connected successfully to EC2."
}
catch {
    Write-Error "Could not connect to EC2!"
}