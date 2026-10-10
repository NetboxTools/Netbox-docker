// NetBox application: PostgreSQL + a single container app (netbox, rq worker and, with redisMode 'sidecar',
// a redis sidecar) protected by Container Apps built-in authentication (Entra ID).
// Requires foundation.bicep to have been deployed and the secrets seeded (scripts/Initialize-NetboxSecrets.ps1).

param serviceName string = 'netbox'
param location string = resourceGroup().location
param tags object = {}

@description('Outputs of foundation.bicep.')
param containerRegistryName string
param keyVaultName string
param containerAppsEnvironmentName string
param identityName string

@description('Tag of the netbox image in the container registry.')
param netboxImageTag string

@description('Client ID of the Entra app registration used to sign users in (clientId output of infra/entra.bicep, passed by scripts/Deploy-Netbox.ps1).')
param entraClientId string

@description('UPN of the first NetBox superuser. Must match the Entra sign-in name exactly. Empty = no superuser is created.')
param initialSuperuserUpn string = ''

@description('Models viewable by every signed-in user, even without explicit permissions.')
param exemptViewPermissions array = []

@description('Entra app role (and NetBox group) whose members become NetBox superusers.')
param adminRole string = 'netbox-admins'

@description('''Where Redis runs. sidecar: an in-memory container in the app (cheap, lost on restart).
managed: Azure Managed Redis (survives restarts, has an SLA with high availability).''')
@allowed([
  'sidecar'
  'managed'
])
param redisMode string = 'sidecar'

@description('Redis image (repository:tag) in the container registry, imported by the pipeline. Used by the sidecar.')
param redisImage string

@description('Azure Managed Redis SKU (redisMode managed).')
param managedRedisSku string = 'Balanced_B0'

@description('Azure Managed Redis high availability (redisMode managed). Only highly available caches have an SLA.')
param managedRedisHighAvailability bool = true

@description('Write the managed Redis access key to Key Vault. scripts/Deploy-Netbox.ps1 sets this only when the key changed.')
param writeManagedRedisKey bool = true

@description('''Custom host names for NetBox, for example [ 'netbox.contoso.com' ]. Each needs a CNAME to the app's
default FQDN and a TXT record asuid.<host name> with the environment's customDomainVerificationId.''')
param customDomains array = []

@description('''Issued managed certificates in the environment, as '<host name>=<certificate name>;...'.
Passed by scripts/Deploy-Netbox.ps1. A host name without one is added unbound and gets a new managed certificate;
the script then deploys again to bind it.''')
param existingCertificates string = ''

param bannerTop string = ''
param bannerLogin string = ''

param postgresAdministratorLogin string = 'netboxadmin'
param postgresDatabaseName string = 'netbox'

var appName = 'ca-${serviceName}'
var redisImageRef = '${containerRegistry.properties.loginServer}/${redisImage}'
var netboxImage = '${containerRegistry.properties.loginServer}/netbox:${netboxImageTag}'
var netboxFqdn = '${appName}.${containerAppsEnvironment.properties.defaultDomain}'
// The default FQDN stays valid (probes and the Entra callback use it); custom domains come first so NetBox prefers them
var netboxHosts = concat(customDomains, [netboxFqdn])
var managedCertificates = toObject(
  filter(split(existingCertificates, ';'), c => !empty(c)),
  c => split(c, '=')[0],
  c => split(c, '=')[1]
)
var newCertificateDomains = filter(customDomains, d => !contains(managedCertificates, d))
var createSuperuser = !empty(initialSuperuserUpn)
var useManagedRedis = redisMode == 'managed'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    name: 'psql-${serviceName}-${uniqueString(resourceGroup().id)}'
    location: location
    tags: tags
    administratorLogin: postgresAdministratorLogin
    administratorLoginPassword: keyVault.getSecret('postgres-admin-password')
    databaseName: postgresDatabaseName
  }
}

var managedRedisKeySecretName = 'managed-redis-access-key'

module managedRedis 'modules/managed-redis.bicep' = if (useManagedRedis) {
  name: 'managed-redis'
  params: {
    name: 'redis-${serviceName}-${uniqueString(resourceGroup().id)}'
    location: location
    tags: tags
    keyVaultName: keyVault.name
    skuName: managedRedisSku
    highAvailability: managedRedisHighAvailability
    accessKeySecretName: managedRedisKeySecretName
    writeAccessKey: writeManagedRedisKey
  }
}

// Azure Managed Redis has a single database (0) and requires TLS. The queues and the cache share it,
// which is safe because their keys don't overlap.
var redisConnection = useManagedRedis
  ? {
      host: managedRedis!.outputs.hostName
      port: string(managedRedis!.outputs.port)
      ssl: 'True'
      tasksDatabase: '0'
      cacheDatabase: '0'
    }
  : {
      host: 'localhost'
      port: '6379'
      ssl: 'False'
      tasksDatabase: '0'
      cacheDatabase: '1'
    }
// Separate from redisConnection: the secret list must be known when the deployment starts
var redisPasswordSecret = useManagedRedis ? managedRedisKeySecretName : 'redis-password'

// Container app secrets, resolved from Key Vault at runtime by the user-assigned identity
var keyVaultSecrets = [
  { name: 'db-password', secret: 'postgres-admin-password' }
  { name: 'secret-key', secret: 'netbox-secret-key' }
  { name: 'redis-password', secret: redisPasswordSecret }
  { name: 'superuser-password', secret: 'netbox-superuser-password' }
  { name: 'api-token-pepper', secret: 'netbox-api-token-pepper' }
  { name: 'microsoft-provider-authentication-secret', secret: 'entra-client-secret' }
]

var sharedEnv = [
  { name: 'DB_HOST', value: postgres.outputs.fqdn }
  { name: 'DB_NAME', value: postgresDatabaseName }
  { name: 'DB_USER', value: postgresAdministratorLogin }
  { name: 'DB_PASSWORD', secretRef: 'db-password' }
  { name: 'DB_SSLMODE', value: 'require' }
  { name: 'REDIS_HOST', value: redisConnection.host }
  { name: 'REDIS_PORT', value: redisConnection.port }
  { name: 'REDIS_SSL', value: redisConnection.ssl }
  { name: 'REDIS_DATABASE', value: redisConnection.tasksDatabase }
  { name: 'REDIS_PASSWORD', secretRef: 'redis-password' }
  { name: 'REDIS_CACHE_HOST', value: redisConnection.host }
  { name: 'REDIS_CACHE_PORT', value: redisConnection.port }
  { name: 'REDIS_CACHE_SSL', value: redisConnection.ssl }
  { name: 'REDIS_CACHE_DATABASE', value: redisConnection.cacheDatabase }
  { name: 'REDIS_CACHE_PASSWORD', secretRef: 'redis-password' }
  { name: 'SECRET_KEY', secretRef: 'secret-key' }
  { name: 'API_TOKEN_PEPPER_1', secretRef: 'api-token-pepper' }
  { name: 'ALLOWED_HOSTS', value: join(netboxHosts, ' ') }
  { name: 'CSRF_TRUSTED_ORIGINS', value: join(map(netboxHosts, h => 'https://${h}'), ' ') }
  // Container Apps authentication signs every request in with Entra ID before it reaches NetBox
  // and passes the user's sign-in name in the X-MS-CLIENT-PRINCIPAL-NAME header.
  { name: 'REMOTE_AUTH_ENABLED', value: 'True' }
  { name: 'REMOTE_AUTH_BACKEND', value: 'netbox_easyauth.EasyAuthRemoteUserBackend' }
  { name: 'REMOTE_AUTH_HEADER', value: 'HTTP_X_MS_CLIENT_PRINCIPAL_NAME' }
  { name: 'REMOTE_AUTH_USER_EMAIL', value: 'HTTP_X_MS_CLIENT_PRINCIPAL_NAME' }
  { name: 'REMOTE_AUTH_AUTO_CREATE_USER', value: 'True' }
  // Entra app roles become NetBox groups on every sign-in (app/netbox_easyauth.py); Entra is the source of truth
  { name: 'REMOTE_AUTH_GROUP_SYNC_ENABLED', value: 'True' }
  { name: 'REMOTE_AUTH_AUTO_CREATE_GROUPS', value: 'True' }
  { name: 'REMOTE_AUTH_SUPERUSER_GROUPS', value: adminRole }
  // Break-glass: the initial superuser stays superuser even if their token carries no app roles
  { name: 'REMOTE_AUTH_SUPERUSERS', value: initialSuperuserUpn }
  // Re-sign-in (and so role re-sync) at least every 8 hours
  { name: 'LOGIN_TIMEOUT', value: '28800' }
  { name: 'LOGIN_REQUIRED', value: 'True' }
  { name: 'EXEMPT_VIEW_PERMISSIONS', value: join(exemptViewPermissions, ' ') }
  { name: 'BANNER_TOP', value: bannerTop }
  { name: 'BANNER_LOGIN', value: bannerLogin }
]

var superuserEnv = createSuperuser
  ? [
      { name: 'SKIP_SUPERUSER', value: 'false' }
      { name: 'SUPERUSER_NAME', value: initialSuperuserUpn }
      { name: 'SUPERUSER_EMAIL', value: initialSuperuserUpn }
      { name: 'SUPERUSER_PASSWORD', secretRef: 'superuser-password' }
    ]
  : [
      { name: 'SKIP_SUPERUSER', value: 'true' }
    ]

// Only reachable on localhost from the other containers in this app
var redisSidecar = {
  name: 'redis'
  image: redisImageRef
  command: [
    '/bin/sh'
    '-c'
    'exec redis-server --save "" --appendonly no --requirepass "$REDIS_PASSWORD"'
  ]
  resources: {
    cpu: json('0.25')
    memory: '0.5Gi'
  }
  env: [
    { name: 'REDIS_PASSWORD', secretRef: 'redis-password' }
  ]
}

resource netbox 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: identity.id
        }
      ]
      secrets: [
        for s in keyVaultSecrets: {
          name: s.name
          keyVaultUrl: '${keyVault.properties.vaultUri}secrets/${s.secret}'
          identity: identity.id
        }
      ]
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        // A host name is bound with its managed certificate once that exists. Until then it is added
        // unbound, which the managed certificate below needs before it can be issued.
        customDomains: [
          for domain in customDomains: contains(managedCertificates, domain)
            ? {
                name: domain
                bindingType: 'SniEnabled'
                certificateId: '${containerAppsEnvironment.id}/managedCertificates/${managedCertificates[domain]}'
              }
            : {
                name: domain
                bindingType: 'Disabled'
              }
        ]
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      terminationGracePeriodSeconds: 60
      containers: concat([
        {
          name: 'netbox'
          image: netboxImage
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: concat(sharedEnv, superuserEnv)
          probes: [
            {
              // First start runs all database migrations, which takes a while
              type: 'Startup'
              httpGet: {
                path: '/login/'
                port: 8080
                // Probes default to the pod IP as Host, which Django rejects (ALLOWED_HOSTS)
                httpHeaders: [
                  { name: 'Host', value: netboxFqdn }
                ]
              }
              initialDelaySeconds: 30
              periodSeconds: 10
              failureThreshold: 60
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/login/'
                port: 8080
                // Probes default to the pod IP as Host, which Django rejects (ALLOWED_HOSTS)
                httpHeaders: [
                  { name: 'Host', value: netboxFqdn }
                ]
              }
              periodSeconds: 30
              failureThreshold: 5
            }
          ]
        }
        {
          name: 'netbox-worker'
          image: netboxImage
          args: [
            '/opt/netbox/venv/bin/python'
            '/opt/netbox/netbox/manage.py'
            'rqworker'
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: sharedEnv
        }
      ], useManagedRedis ? [] : [redisSidecar])
      // A redis sidecar is per replica, and uploaded media is stored in the container, so NetBox runs
      // as a single replica
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// Free certificates managed (and renewed) by Container Apps, validated through the CNAME to the app
resource certificates 'Microsoft.App/managedEnvironments/managedCertificates@2024-03-01' = [
  for domain in newCertificateDomains: {
    parent: containerAppsEnvironment
    name: 'mc-${take(replace(domain, '.', '-'), 57)}'
    location: location
    tags: tags
    properties: {
      subjectName: domain
      domainControlValidation: 'CNAME'
    }
    dependsOn: [
      netbox
    ]
  }
]

// Every request must be signed in with Entra ID before it reaches NetBox
resource netboxAuth 'Microsoft.App/containerApps/authConfigs@2024-03-01' = {
  parent: netbox
  name: 'current'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: entraClientId
          clientSecretSettingName: 'microsoft-provider-authentication-secret'
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
        }
      }
    }
    httpSettings: {
      requireHttps: true
    }
  }
}

output netboxUrl string = 'https://${netboxHosts[0]}'
output netboxDefaultUrl string = 'https://${netboxFqdn}'
output redisHost string = redisConnection.host
output newCertificateDomains array = newCertificateDomains
output postgresFqdn string = postgres.outputs.fqdn
