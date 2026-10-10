// Foundation for NetBox: everything that must exist before images can be built
// and before the application is deployed (registry, Key Vault, identity, Container Apps environment).

param serviceName string = 'netbox'
param location string = resourceGroup().location
param tags object = {}

var suffix = uniqueString(resourceGroup().id)

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${serviceName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${serviceName}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'cr${serviceName}${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${serviceName}-${take(suffix, 8)}'
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true
    // Deleted secrets stay recoverable for 90 days and cannot be purged. The pipeline can't
    // recreate a soft-deleted name, so the secret key and API token pepper are never silently replaced.
    // Cannot be turned off once enabled.
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    sku: {
      name: 'standard'
      family: 'A'
    }
  }
}

// Identity used by the container app to pull images and read secrets.
// User-assigned so its role assignments (scripts/Grant-NetboxAccess.ps1) can exist before the app's first revision starts.
// The pipeline identity (Contributor-style rights) cannot create role assignments, so they are granted out-of-band.
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${serviceName}'
  location: location
  tags: tags
}

output containerRegistryId string = containerRegistry.id
output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output containerAppsEnvironmentName string = containerAppsEnvironment.name
output identityName string = identity.name
output identityPrincipalId string = identity.properties.principalId
output netboxFqdn string = 'ca-${serviceName}.${containerAppsEnvironment.properties.defaultDomain}'
@description('Value of the TXT record asuid.<host name> that every custom domain needs.')
output customDomainVerificationId string = containerAppsEnvironment.properties.customDomainConfiguration.customDomainVerificationId
