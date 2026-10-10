using '../entra.bicep'

param serviceName = 'netbox'
param displayName = 'app-netbox-prod-login'

// Passed by scripts/Deploy-NetboxEntra.ps1: the foundation's netboxFqdn and the customDomains
// from prod.bicepparam, so the redirect URIs always match the app.
param netboxFqdn = ''
param customDomains = ''
