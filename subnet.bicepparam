using './subnet.bicep'

param nsgName = 'nsg-postgresql'
param location = 'Sweden Central'
param tags = {}
param subnetRange = 'mysubnetrange'
param hubFirewallIp = 'myfirewall'
param vnetName = 'vnet-infra-shared'
param subnetName = 'snet-postgresql'
param environment = ''
