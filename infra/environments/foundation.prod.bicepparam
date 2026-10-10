using '../foundation.bicep'

param serviceName = 'netbox'
param tags = {
  service: 'netbox'
  environment: 'prod'
}
