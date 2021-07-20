param (
    $octopusUrl
)

Write-Output "Retrieving all AWS Secrets Manager secrets to verify they exist"

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
    $errorMessage = "Missing secrets: " + $missingSecrets + " Hint: Did you create your secrets in the correct AWS region? They need to be in the same region as your instances."
}

# Checking some of the secrets are in the expected format
if ("OCTOPUS_APIKEY" -notin $missingSecrets){
    # Checking API key starts with "API-"
    if ($octopus_apikey -notlike "API-*"){
        Write-Warning  "OCTOPUS_APIKEY doesn't start: ""API-"". "
        $badSecretMessages = $badSecretMessages + "OCTOPUS_APIKEY doesn't start: ""API-"". "
    }
    # Cheking API key is correct length
    if (($octopus_apikey.length -gt 40) -or ($octopus_apikey.length -lt 32)){
        $OctoApiKeyLength = $octopus_apikey.length
        Write-Warning "OCTOPUS_APIKEY is $OctoApiKeyLength chars (should be about 36). "
        $badSecretMessages = $badSecretMessages + "OCTOPUS_APIKEY is $OctoApiKeyLength chars (should be about 36). "
    }
    # Checking API key works
    Write-Output "Executing a simple API call to retrieve Octopus Spaces data to verify that we can authenticate against Octopus instance."
    try {
        $header = @{ "X-Octopus-ApiKey" = $OctoApiKey }
        $spaces = (Invoke-WebRequest $octopusUrl/api/spaces -Headers $header)
        Write-Output "That seems to work."
    }
    catch {
        Write-Warning  "OCTOPUS_APIKEY auth fails for: $octopusUrl. "
        $badSecretMessages = $badSecretMessages + "OCTOPUS_APIKEY auth fails for: $octopusUrl. "    
    }
}

if ("OCTOPUS_THUMBPRINT" -notin $missingSecrets){
    # Checking Octopus Thumbprint is correct length (40 chars)
    if (-not ($octopus_thumbprint.length -eq 40)){
        $OctoThumbprintLength = $octopus_thumbprint.length
        Write-Warning "OCTOPUS_THUMBPRINT is $OctoThumbprintLength chars (should be 40). "
        $badSecretMessages = $badSecretMessages + "OCTOPUS_THUMBPRINT is $OctoThumbprintLength chars (should be 40). "
    } 
}

# Logging password validation results
if ($badSecretMessages -notlike ""){
    $errorMessage = "$errorMesage There are problems with the following secrets: $badSecretMessages"
}
if ($errorMessage -notlike ""){
    $newStatus = "FAILED-AwsSecretsValidationErrors: $errorMessage"
    # Tag values can be max 256 chars
    if ($newStatus.length -gt 255){
        $newStatus = $newStatus.SubString(0,213) + " ... (see log in c:/startupfor full error)" # additional string is 42 chars. 213 + 42 = 255
    }
    Update-StatupStatus -status $newStatus
    Write-Error "$errorMessage"
} else {
    Write-Output "All required AWS Secrets are present and pass validation checks."
}





