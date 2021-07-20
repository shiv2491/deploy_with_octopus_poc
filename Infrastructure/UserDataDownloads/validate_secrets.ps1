param (
    $octopusUrl
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
    $errorMessage = "Missing secrets: " + $missingSecrets + " Hint: Did you create your secrets in the correct AWS region? They need to be in the same region as your instances."
}

# Checking some of the secrets are in the expected format
if ("OCTOPUS_APIKEY" -notin $missingSecrets){
    # Checking API key starts with "API-"
    if ($octopus_apikey -notlike "API-*"){
        Write-Warning "OCTOPUS_APIKEY in AWS Secrets is: $octopus_apikey"
        $badSecretMessages = $badSecretMessages + "OCTOPUS_APIKEY does not start with ""API-"". "
    }
    # Cheking API key is correct length
    if (-not ($octopus_apikey.length -eq 36)){
        $OctoApiKeyLength = $octopus_apikey.length
        Write-Warning  "OCTOPUS_APIKEY in AWS Secrets is: $octopus_apikey"
        $badSecretMessages = $badSecretMessages + "OCTOPUS_APIKEY is not the correct length (Expected: 36 chars, Actual: $OctoApiKeyLength). "
    }
    # Checking API key works
    Write-Output "Executing a simple API call to retrieve Octopus Spaces data to verify that we can authenticate against Octopus instance."
    try {
        $header = @{ "X-Octopus-ApiKey" = $OctoApiKey }
        $spaces = (Invoke-WebRequest $octopusUrl/api/spaces -Headers $header)
        Write-Output "That seems to work."
    }
    catch {
        Write-Warning  "OCTOPUS_APIKEY from AWS fails to authenticate with Octopus Deploy instance: $octopusUrl"
        $badSecretMessages = $badSecretMessages + "OCTOPUS_APIKEY from AWS fails to authenticate with Octopus Deploy instance: $octopusUrl. "    
    }
}

if ("OCTOPUS_THUMBPRINT" -notin $missingSecrets){
    # Checking Octopus Thumbprint is correct length (40 chars)
    if (-not ($octopus_thumbprint.length -eq 40)){
        $OctoThumbprintLength = $octopus_thumbprint.length
        Write-Warning  "OCTOPUS_THUMBPRINT in AWS Secrets is: $OctoThumbprintLength"
        $badSecretMessages = $badSecretMessages + "OCTOPUS_THUMBPRINT is not the correct length (Expected: 40 chars, Actual: $OctoThumbprintLength). "
    } 
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





