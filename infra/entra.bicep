// Entra app registration that NetBox users sign in with (Microsoft Graph Bicep).
// Deployed by scripts/Deploy-NetboxEntra.ps1 in the pipeline's Foundation stage.
//
// The pipeline identity needs the Microsoft Graph application permission Application.ReadWrite.OwnedBy
// (scripts/Initialize-PipelineAccess.ps1 -GrantGraphPermission), which only covers apps it owns.
// Two things deliberately stay out of the pipeline (scripts/Set-NetboxLoginAccess.ps1):
//   - assigning groups to app roles: it would need AppRoleAssignment.ReadWrite.All, which can grant
//     any app role in the tenant
//   - the client secret: Graph Bicep cannot create application passwords

extension microsoftGraphV1

param serviceName string = 'netbox'

@description('Display name of the app registration and enterprise app.')
param displayName string

@description('Default FQDN of the container app (netboxFqdn output of foundation.bicep).')
param netboxFqdn string

@description('Custom host names, comma-separated (customDomains in prod.bicepparam). A string, not an array, so it passes through az on Windows.')
param customDomains string = ''

var hosts = concat([netboxFqdn], filter(split(customDomains, ','), d => !empty(d)))

// The role values are the NetBox group names used by app/netbox_easyauth.py and infra/main.bicep.
// IDs are derived from the resource group, so they stay the same on every deployment and existing
// assignments keep working.
var appRoles = [
  {
    value: 'netbox-admins'
    displayName: 'NetBox Admin'
    description: 'Full NetBox administration (superuser).'
  }
  {
    value: 'netbox-editors'
    displayName: 'NetBox Editor'
    description: 'Create, edit and delete NetBox data, without administration.'
  }
  {
    value: 'netbox-readers'
    displayName: 'NetBox Reader'
    description: 'Read-only access to NetBox.'
  }
]

var graphAppId = '00000003-0000-0000-c000-000000000000'
var graphUserReadScope = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'

resource app 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: '${serviceName}-login-${uniqueString(resourceGroup().id)}'
  displayName: displayName
  signInAudience: 'AzureADMyOrg'
  web: {
    redirectUris: [for host in hosts: 'https://${host}/.auth/login/aad/callback']
    implicitGrantSettings: {
      enableIdTokenIssuance: true
    }
  }
  appRoles: [
    for role in appRoles: {
      id: guid(resourceGroup().id, 'netbox-app-role', role.value)
      value: role.value
      displayName: role.displayName
      description: role.description
      allowedMemberTypes: [
        'User'
      ]
      isEnabled: true
    }
  ]
  requiredResourceAccess: [
    {
      resourceAppId: graphAppId
      resourceAccess: [
        {
          id: graphUserReadScope
          type: 'Scope'
        }
      ]
    }
  ]
  owners: {
    relationships: [
      deployer().objectId
    ]
  }
}

resource servicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: app.appId
  // Only users in groups assigned to an app role can sign in
  appRoleAssignmentRequired: true
  owners: {
    relationships: [
      deployer().objectId
    ]
  }
}

output clientId string = app.appId
output applicationObjectId string = app.id
output servicePrincipalId string = servicePrincipal.id
output displayName string = displayName
