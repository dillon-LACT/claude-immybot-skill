<#
    Template — copy into a project and fill in real values (or set the env vars below
    before dot-sourcing). Do not commit a filled-in copy with a real client secret to a
    public/shared repo.

    Dot-source to get $headers (and $tok) ready for any ImmyBot API call:
        . .\Connect-ImmyBot.ps1

    Auth: Azure AD OAuth2 client-credentials flow against an ImmyBot tenant's own app
    registration (Entra ID > App registrations > your ImmyBot API app), not a user login.
#>

$tenantId     = $env:IMMYBOT_AAD_TENANT_ID   # Azure AD tenant ID that owns the app registration
$clientId     = $env:IMMYBOT_CLIENT_ID       # App registration's Application (client) ID
$clientSecret = $env:IMMYBOT_CLIENT_SECRET   # App registration's client secret value
$immyBase     = $env:IMMYBOT_BASE_URL        # e.g. https://yourcompany.immy.bot

if (-not ($tenantId -and $clientId -and $clientSecret -and $immyBase)) {
    throw "Set IMMYBOT_AAD_TENANT_ID, IMMYBOT_CLIENT_ID, IMMYBOT_CLIENT_SECRET, IMMYBOT_BASE_URL before dot-sourcing this script."
}

$tok = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = "$immyBase/.default"
}).access_token

$headers = @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" }

Write-Host "Connected to $immyBase - `$headers is ready to use." -ForegroundColor Green
