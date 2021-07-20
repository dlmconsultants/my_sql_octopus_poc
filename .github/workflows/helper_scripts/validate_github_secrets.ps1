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

# Checking API key works
Write-Output "Executing a simple API call to retrieve Octopus Spaces data to verify that we can authenticate against Octopus instance."
$apikeyWorks = $false
try {
    $header = @{ "X-Octopus-ApiKey" = $OctoApiKey }
    $spaces = (Invoke-WebRequest $OctoUrl/api/spaces -Headers $header)
    Write-Output "That seems to work."
    $apikeyWorks = $true
}
catch {
    Write-Warning  "OCTOPUS_APIKEY auth fails for: $OctoUrl. "  
}
if (-not $apikeyWorks){
    # Checking API key starts with "API-"
    if ($octopus_apikey -notlike "API-*"){
        Write-Warning  "OCTOPUS_APIKEY doesn't start: ""API-"". "
    }
    # Cheking API key is roughly the correct length (about 36 chars - not always exact)
    if (($octopus_apikey.length -gt 38) -or ($octopus_apikey.length -lt 34)){
        $OctoApiKeyLength = $octopus_apikey.length
        Write-Warning "OCTOPUS_APIKEY is $OctoApiKeyLength chars (should be about 36). "
    }
}
