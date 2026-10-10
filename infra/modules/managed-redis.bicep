// Azure Managed Redis for NetBox's job queues and cache (redisMode = 'managed').
// NetBox can only authenticate to Redis with a password, so access keys are enabled and the
// primary key is stored in Key Vault, where the container app reads it like its other secrets.

param name string
param location string
param tags object
param keyVaultName string

@description('Azure Managed Redis SKU, e.g. Balanced_B0.')
param skuName string

@description('Replicate to a second node. Only caches with high availability are covered by the SLA.')
param highAvailability bool

@description('Name of the Key Vault secret that receives the access key.')
param accessKeySecretName string

@description('Write the access key to Key Vault. False when the stored key is already current.')
param writeAccessKey bool = true

resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    highAvailability: highAvailability ? 'Enabled' : 'Disabled'
    minimumTlsVersion: '1.2'
    // Reachable with the access key over TLS; move to a private endpoint along with PostgreSQL
    publicNetworkAccess: 'Enabled'
  }
}

resource database 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: redis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    // Behaves like a single Redis server: RQ uses multi-key commands that a sharded cluster rejects
    clusteringPolicy: 'NoCluster'
    // When memory is full, evict only keys with a TTL (cache entries, finished job results).
    // Queues and pending jobs have no TTL, so they are never evicted.
    evictionPolicy: 'VolatileLRU'
    accessKeysAuthentication: 'Enabled'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource accessKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (writeAccessKey) {
  parent: keyVault
  name: accessKeySecretName
  properties: {
    // listKeys belongs to the database, not the cluster
    value: database.listKeys().primaryKey
  }
}

output hostName string = redis.properties.hostName
output port int = database.properties.port
