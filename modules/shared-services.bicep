// Shared services — private-by-default Key Vault in the hub.
//
// The vault is reachable only through a private endpoint in the hub's
// SharedServices subnet, with RBAC-mode authorization and purge protection.
// A private DNS zone group wires the endpoint into the centrally linked
// vault Private DNS zone, so the vault name resolves to the endpoint IP
// from every VNet. Audit logs stream to the central workspace.

targetScope = 'resourceGroup'

@description('Azure region for the vault and endpoint.')
param location string

@description('Tags applied to every taggable resource.')
param tags object = {}

@description('Name of the Key Vault. Key Vault names are globally unique — pick your own.')
param keyVaultName string

@description('Resource ID of the hub SharedServices subnet for the private endpoint.')
param hubSubnetId string

@description('Resource ID of the centrally linked vault Private DNS zone.')
param privateDnsZoneIdVault string

@description('Resource ID of the central Log Analytics workspace for audit diagnostics.')
param logAnalyticsWorkspaceId string

@description('Soft-delete retention in days.')
param softDeleteRetentionInDays int = 90

@description('Variable-driven data-plane role assignments: each entry grants one principal one Key Vault data-plane role. Empty by default — no assignments are emitted until entries are supplied.')
param dataPlaneRoleAssignments array = []

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-${keyVaultName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: hubSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'kv-plc'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: privateDnsZoneIdVault
        }
      }
    ]
  }
}

resource vaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${keyVaultName}'
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource vaultRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (assignment, i) in dataPlaneRoleAssignments: {
    name: guid(vault.id, assignment.principalId, assignment.roleDefinitionId)
    scope: vault
    properties: {
      roleDefinitionId: assignment.roleDefinitionId
      principalId: assignment.principalId
      principalType: 'ServicePrincipal'
    }
  }
]

output keyVaultId string = vault.id
output keyVaultName string = vault.name
output keyVaultUri string = vault.properties.vaultUri
