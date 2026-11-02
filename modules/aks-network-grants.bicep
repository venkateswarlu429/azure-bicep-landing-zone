// Network Contributor grants for the AKS cluster identity.
//
// The cluster identity needs Network Contributor on the workload VNet and
// on the spoke route table (UDR clusters require it). Role assignments are
// extension resources, so they must deploy in the resource group that owns
// their scope targets — callers deploy this module with scope set to the
// networking resource group, and the existing VNet / route table resolve
// inside that scope.

targetScope = 'resourceGroup'

@description('Name of the workload spoke VNet.')
param vnetName string

@description('Name of the workload spoke route table.')
param routeTableName string

@description('Principal ID of the AKS cluster identity.')
param principalId string

@description('Role definition resource ID for Network Contributor.')
param roleDefinitionId string = '/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212'

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: vnetName
}

resource routeTable 'Microsoft.Network/routeTables@2023-09-01' existing = {
  name: routeTableName
}

resource raVnet 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, principalId, 'network-contributor')
  scope: vnet
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource raRouteTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(routeTable.id, principalId, 'network-contributor')
  scope: routeTable
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
