param serviceName string
param location string = resourceGroup().location
param netboxPostgreAdministratorUserName string

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: 'crnetbox'
  scope: resourceGroup('rg-cae')
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: 'kv-${serviceName}'
  location: location
  properties: {
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: true
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    sku: {
      name: 'standard'
      family: 'A'
    }
  }
}

resource netboxPostgreAdministratorUserNameSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: 'netboxPostgreAdministratorUserName'
  parent: keyVault
  properties: {
    value: netboxPostgreAdministratorUserName
    attributes: {
      enabled: true
    }
  }
}

resource containerRegistryAdministratorPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: 'containerRegistryAdministratorPassword'
  parent: keyVault
  properties: {
    value: containerRegistry.listCredentials().passwords[0].value
    attributes: {
      enabled: true
    }
  }
}

resource containerRegistryAdministratorUserNameSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: 'containerRegistryAdministratorUserName'
  parent: keyVault
  properties: {
    value: containerRegistry.listCredentials().username
    attributes: {
      enabled: true
    }
  }
}
