using '../main.bicep'

// Deployment-specific values (foundation outputs, image tag, Entra client ID, superuser)
// are passed by the pipeline from pipelines/variables/prod.yml.
param serviceName = 'netbox'
param tags = {
  service: 'netbox'
  environment: 'prod'
}
// NetBox settings. The image's own configuration.py reads these from environment variables.
// Nothing is viewable without a role; readers get their permission from app/netbox_easyauth.py
param exemptViewPermissions = []
// Custom host names, e.g. [ 'netbox.contoso.com' ]. Create the DNS records first (see README).
param customDomains = []
// 'sidecar' (in-memory container, default) or 'managed' (Azure Managed Redis, see README)
param redisMode = 'sidecar'
param bannerTop = 'Contoso Production NetBox'
param bannerLogin = 'Contoso Production NetBox. For access questions, contact the platform team.'

param containerRegistryName = ''
param keyVaultName = ''
param containerAppsEnvironmentName = ''
param identityName = ''
param netboxImageTag = ''
param redisImage = ''
param entraClientId = ''
