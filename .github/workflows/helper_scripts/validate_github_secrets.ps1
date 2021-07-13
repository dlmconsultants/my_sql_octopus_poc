param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]$OctoUrl,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()]$OctoApiKey
)

$ErrorActionPreference = "Stop"  

$errors = @()

# Checking Octopus URL is in the correct format
# (Note: this script assumes you are using a cloud instance)
if ($octoUrl -like "https://*.octopus.app/"){
    Write-Output "OCTOPUS_URL is in the correct format: https://*.octopus.app/"
}
else {
    $errors += "Octopus URL is not in the correct format (https://*.octopus.app/). "
}

# Checking Octopus API Key is in the correct format
# (Must start with "API-")
if ($octoApiKey -like "API-*"){
    Write-Output "OCTOPUS_APIKEY is in the correct format: API-*"
}
else {
    $errors += "OCTOPUS_APIKEY is not in the correct format (API-*). "
}

# Checking Octopus API Key is the correct length
# (Must be 36 characters long)
if ($octoApiKey.length -eq 36){
    Write-Output "OCTOPUS_APIKEY is the correct length: 36 characters"
}
else {
    $OctoApiKeyLength = $octoApiKey.length
    $errors += "OCTOPUS_APIKEY is not the correct length (Expected: 36 chars, Actual: $OctoApiKeyLength). "
}

# If any of the checks failed, raise an error
if ($errors.Count -gt 0){
    $errorMsg = "The required GitHub secrets are not set up correctly: "
    ForEach ($fail in $errors){
        $errorMsg = $errorMsg + $fail
    }
    Write-Error $errorMsg
}