// Monitoring — one central Log Analytics workspace in the management
// subscription. Every other module streams diagnostics into it, so there is
// a single logging sink, one retention policy, and one place to query across
// firewall, Key Vault, and AKS.

targetScope = 'resourceGroup'

@description('Azure region for the workspace.')
param location string

@description('Tags applied to the workspace.')
param tags object = {}

@description('Workspace name.')
param workspaceName string = 'law-alz-mgmt'

@description('Retention in days for ingested logs.')
param retentionInDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
