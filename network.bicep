param location string = resourceGroup().location

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-netbox'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '192.168.0.0/22'
      ]
    }
    subnets: [
      {
        name: 'snet-general'
        properties: {
          addressPrefix: '192.168.0.0/25'
          networkSecurityGroup: {
            id: networkSecurityGroupgeneral.id
          }
          routeTable: {
            id: routeTablegeneral.id
          }
        }
      }
      {
        name: 'snet-netbox-postgresql'
        properties: {
          addressPrefix: '192.168.0.128/28'
          networkSecurityGroup: {
            id: networkSecurityGroupPostgresql.id
          }
          routeTable: {
            id: routeTablePostgresql.id
          }
          delegations: [
            {
              name: 'Microsoft.DBforPostgreSQL/flexibleServers'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
      {
        name: 'snet-netbox-containerapp'
        properties: {
          addressPrefix: '192.168.0.160/27'
          networkSecurityGroup: {
            id: networkSecurityGroupContainerapp.id
          }
          routeTable: {
            id: routeTableContainerapp.id
          }
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

resource networkSecurityGroupgeneral 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-general'
  location: location
  properties: {}
}

resource networkSecurityGroupPostgresql 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-netbox-postgresql'
  location: location
  properties: {}
}

resource networkSecurityGroupContainerapp 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-netbox-containerapp'
  location: location
  properties: {}
}

resource routeTablegeneral 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-general'
  location: location
  properties: {
    routes: [
      {
        name: 'default'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.92.1.4'
        }
      }
    ]
    disableBgpRoutePropagation: true
  }
}

resource routeTablePostgresql 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-netbox-postgresql'
  location: location
  properties: {
    routes: [
      {
        name: 'default'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.92.1.4'
        }
      }
      {
        name: 'AzureActiveDirectory'
        properties: {
          addressPrefix: 'AzureActiveDirectory'
          nextHopType: 'Internet'
        }
      }
    ]
    disableBgpRoutePropagation: true
  }
}

resource routeTableContainerapp 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-netbox-containerapp'
  location: location
  properties: {
    routes: [
      {
        name: 'default'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.92.1.4'
        }
      }
    ]
    disableBgpRoutePropagation: true
  }
}
