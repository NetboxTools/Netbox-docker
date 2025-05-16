param nsgName string
param location string
param tags object
param subnetRange string
param hubFirewallIp string
param vnetName string
param subnetName string
param environment string

resource Vnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: vnetName
}

resource Subnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: Vnet
  name: subnetName
  properties: {
    addressPrefix: subnetRange
    delegations: [
      {
        name: 'Microsoft.DBforPostgreSQL/flexibleServers'
        properties: {
          serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
        }
      }
    ]
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
    routeTable: {
      id: routeTable.id
    }
  }
}

resource routeTable 'Microsoft.Network/routeTables@2023-04-01' = {
  name: 'rt-postgresql-${environment}'
  location: location
  tags: tags
  properties: {
    routes: [
      {
        name: 'default-udr'
        properties: {
          nextHopType: 'VirtualAppliance'
          addressPrefix: '0.0.0.0/0'
          nextHopIpAddress: hubFirewallIp
        }
      }
    ]
    disableBgpRoutePropagation: true
  }
}

// Network Security Group
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Internal-Subnet'
        properties: {
          access: 'Allow'
          description: 'Allow subnet communication'
          direction: 'Inbound'
          priority: 200
          protocol: '*'
          destinationPortRange: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: subnetRange
          destinationAddressPrefix: subnetRange
        }
      }
      {
        name: 'snet-general-to-postgresql'
        properties: {
          access: 'Allow'
          description: 'Allow snet-general to postgresql'
          direction: 'Inbound'
          priority: 201
          protocol: '*'
          destinationPortRange: '5432'
          sourcePortRange: '*'
          sourceAddressPrefix: 'mysourcerange'
          destinationAddressPrefix: subnetRange
        }
      }
    ]
  }
}
