param (
    $expectedOctopusSqlPassword
)

Write-Host "Retrieving all AWS Secrets Manager secrets to verify they exist"

$errorMessage = ""
$missingSecrets = @()
$badSecretMessages = @()

$octopus_apikey = ""
$octopus_thumbprint = ""
$student_sql_password = ""
$octopus_sql_password = ""
$sysadmin_sql_password = ""

# Checking all the secrets exist
try {
    $octopus_apikey = Get-Secret -secret "OCTOPUS_APIKEY"
}
catch {
    $missingSecrets = $missingSecrets + "OCTOPUS_APIKEY"
}
try {
    $octopus_thumbprint = Get-Secret -secret "OCTOPUS_THUMBPRINT"
}
catch {
    $missingSecrets = $missingSecrets + "OCTOPUS_THUMBPRINT"
}
try {
    $student_sql_password = Get-Secret -secret "STUDENT_SQL_PASSWORD"
}
catch {
    $missingSecrets = $missingSecrets + "STUDENT_SQL_PASSWORD"
}
try {
    $octopus_sql_password = Get-Secret -secret "OCTOPUS_SQL_PASSWORD"
}
catch {
    $missingSecrets = $missingSecrets + "OCTOPUS_SQL_PASSWORD"
}
try {
    $sysadmin_sql_password = Get-Secret -secret "SYSADMIN_SQL_PASSWORD"
}
catch {
    $missingSecrets = $missingSecrets + "SYSADMIN_SQL_PASSWORD"
}

if ($missingSecrets.length -gt 0){
    $errorMessage = "Missing secrets: " + $missingSecrets
}

# Checking some of the secrets are in the expected format
if ("OCTOPUS_APIKEY" -notin $missingSecrets){
    if ($octopus_apikey -notlike "API-*"){
        Write-Warning "OCTOPUS_APIKEY in AWS is: $octopus_apikey"
        $badSecretMessages = $badSecretMessages + "OCTOPUS_APIKEY does not start with ""API-"". "
    }
    if (-not ($octopus_apikey.length -eq 36)){
        $OctoApiKeyLength = $octopus_apikey.length
        Write-Warning  "OCTOPUS_APIKEY in AWS is: $octopus_apikey"
        $badSecretMessages = $badSecretMessages + "OCTOPUS_APIKEY is not the correct length (Expected: 36 chars, Actual: $OctoApiKeyLength). "
    }
}

if (("OCTOPUS_SQL_PASSWORD" -notin $missingSecrets) -and ($octopus_sql_password -notlike $expectedOctopusSqlPassword)){
    Write-Warning  "OCTOPUS_SQL_PASSWORD in AWS is: $octopus_sql_password"
    Write-Warning  "OCTOPUS_SQL_PASSWORD in Octopus is: $expectedOctopusSqlPassword"
    $badSecretMessages = $badSecretMessages + "OCTOPUS_SQL_PASSWORD in Octopus and AWS do not match. "
}

# Logging password validation results
if ($badSecretMessages -notlike ""){
    $errorMessage = "$errorMesage There are problems with the following secrets: $badSecretMessages"
}
if ($errorMessage -notlike ""){
    Update-StatupStatus -status "FAILED-AwsSecretsValidationErrors: $errorMessage"
    Write-Error "$errorMessage"
} else {
    Write-Output "All required AWS Secrets are present and pass validation checks."
}





