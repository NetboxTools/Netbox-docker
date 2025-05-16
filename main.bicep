param serviceName string
param location string = resourceGroup().location
param netboxPostgreAdministratorUserName string
param netboxContainerVersion string = 'latest'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2019-11-01' existing = {
  name: 'vnet-netbox-shared'
  scope: resourceGroup('rg-netbox')
}

resource subnetPostgre 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  name: 'snet-postgresql'
  parent: virtualNetwork
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  name: 'snet-general'
  parent: virtualNetwork
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: 'crnetboxshared'
  scope: resourceGroup('rg-cae')
}

resource CAE 'Microsoft.App/managedEnvironments@2023-08-01-preview' existing = {
  name: 'cae-netbox-shared'
  scope: resourceGroup('rg-cae')
}

var administratorLoginPassword = uniqueString('pg-${serviceName}')
var uniqueStringVar = substring(uniqueString(serviceName),0,4)

resource postgre 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01' = {
  name: 'pg-${serviceName}-${uniqueStringVar}'
  location: location
  properties: {
    administratorLogin: netboxPostgreAdministratorUserName
    administratorLoginPassword: administratorLoginPassword
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
      tenantId: tenant().tenantId
    }
    storage: {
      storageSizeGB: 64
    }
    dataEncryption: {
      type: 'SystemManaged'
    }
    replicationRole: 'Primary'
    network: {
      // publicNetworkAccess: 'Disabled'
      delegatedSubnetResourceId: subnetPostgre.id
      privateDnsZoneArmResourceId: resourceId('bee2685e-d7dd-4f56-84ef-18cd2693ec59', 'rg-private-dns', 'Microsoft.Network/privateDnsZones', 'privatelink.postgres.database.azure.com')
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    version: '16'
  }
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${serviceName}-${uniqueStringVar}'
  location: location
  properties: {
    publicNetworkAccess: 'Disabled'
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

resource netboxPostgreAdministratorPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: 'netboxPostgreAdministratorPasswordSecret'
  parent: keyVault
  properties: {
    value: administratorLoginPassword
    attributes: {
      enabled: true
    }
  }
}

resource privateEndpointKv 'Microsoft.Network/privateEndpoints@2022-01-01' = {
  name: 'pep-${keyVault.name}'
  location: location
  properties: {
    privateLinkServiceConnections: [
      {
        name: keyVault.name
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
    subnet: {
      id: subnet.id
    }
  }
}

resource Netbox 'Microsoft.App/containerApps@2023-08-01-preview' = {
  name: 'ca-netbox'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: CAE.id
    environmentId: CAE.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: 'system'
          // passwordSecretRef: 'containerregistryadministratorpassword'
        }
      ]
      secrets: [
      ]
      ingress: {
        allowInsecure: false
        targetPort: 8080
        transport: 'auto'
        external: true
        clientCertificateMode: 'ignore'
        customDomains: [
          {
            name: 'netbox.Contoso.eu'
            bindingType: 'SniEnabled'
            certificateId: resourceId(subscription().subscriptionId,'rg-cae','Microsoft.App/managedEnvironments/certificates',CAE.name,'netbox-Contoso-eu')
          }
        ]
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
        stickySessions: {
          affinity: 'none'
        }
      }
    }
    template: {
      terminationGracePeriodSeconds: 300
      containers: [
        {
          image: '${containerRegistry.properties.loginServer}/Contoso/netbox:${netboxContainerVersion}'
          name: 'netbox'
          resources: {
            cpu: 4
            memory: '8Gi'
          }
          probes: []
          env: [
          ] 
        }

      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

resource Redis 'Microsoft.App/containerApps@2023-08-01-preview' = {
  name: 'ca-redis'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: CAE.id
    environmentId: CAE.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: 'system'
          // passwordSecretRef: 'containerregistryadministratorpassword'
        }
      ]
      secrets: [
      ]
      ingress: {
        allowInsecure: false
        targetPort: 6379
        transport: 'Tcp'
        exposedPort: 6379
        external: true
        stickySessions: {
          affinity: 'none'
        }
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          image: '${containerRegistry.properties.loginServer}/Contoso/redis:7-alpine'
          name: 'redis'
          command: [
            '/bin/sh'
            '-c'
            'redis-server --appendonly yes --requirepass 1338661dd3ea47c2972bd1a6f'
          ]
          resources: {
            cpu: 2
            memory: '4Gi'
          }
          probes: []
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

@description('This is the built-in Key Vault Secrets User role. See https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user')
resource keyvaultSecretsUserRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  scope: subscription()
  name: '4633458b-17de-408a-b874-0445c86b69e6'
}

resource NetboxkeyVault_roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, Netbox.name, keyvaultSecretsUserRoleDefinition.id)
  properties: {
    roleDefinitionId: keyvaultSecretsUserRoleDefinition.id
    principalId: Netbox.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource RediskeyVault_roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, Redis.name, keyvaultSecretsUserRoleDefinition.id)
  properties: {
    roleDefinitionId: keyvaultSecretsUserRoleDefinition.id
    principalId: Redis.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// @description('This is the built-in Key Vault Secrets User role. See https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user')
// resource AcrPullRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
//   scope: subscription()
//   name: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
// }

// resource NetboxACR_roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
//   scope: containerRegistry
//   name: guid(containerRegistry.id, Netbox.name, AcrPullRoleDefinition.id)
//   properties: {
//     roleDefinitionId: AcrPullRoleDefinition.id
//     principalId: Netbox.identity.principalId
//     principalType: 'ServicePrincipal'
//   }
// }

// resource RedisACR_roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
//   scope: containerRegistry
//   name: guid(containerRegistry.id, Redis.name, AcrPullRoleDefinition.id)
//   properties: {
//     roleDefinitionId: AcrPullRoleDefinition.id
//     principalId: Redis.identity.principalId
//     principalType: 'ServicePrincipal'
//   }
// }
