// Foundation for NetBox: everything that must exist before images can be built
// and before the application is deployed (registry, Key Vault, identity, Container Apps environment),
// plus the role assignments the app and the pipeline need.
//
// The pipeline identity creates the role assignments itself. It holds Role Based Access Control
// Administrator on the resource group, restricted by a condition to the roles below and to service
// principals (scripts/Initialize-PipelineAccess.ps1), so it cannot grant anything else.

param serviceName string = 'netbox'
param location string = resourceGroup().location
param tags object = {}

@description('Principal type of the identity running this deployment. ServicePrincipal for the pipeline.')
@allowed([
  'ServicePrincipal'
  'User'
])
param deployerPrincipalType string = 'ServicePrincipal'

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
// User-assigned so its role assignments (below) can exist before the app's first revision starts.
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${serviceName}'
  location: location
  tags: tags
}

// Built-in role definition IDs. They are the same in every tenant, and they must match the condition
// set by scripts/Initialize-PipelineAccess.ps1.
var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
}

// The app pulls images and reads secrets as id-netbox. These exist before the app's first revision starts.
resource identityAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: containerRegistry
  name: guid(containerRegistry.id, identity.id, roles.acrPull)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource identitySecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, identity.id, roles.keyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// The pipeline generates the secrets (scripts/Initialize-NetboxSecrets.ps1) and reads them to deploy
resource deployerSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, deployer().objectId, roles.keyVaultSecretsOfficer)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsOfficer)
    principalId: deployer().objectId
    principalType: deployerPrincipalType
  }
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
