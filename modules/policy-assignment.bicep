// Policy assignment at management-group scope.
//
// Policy assignments are extension resources: their scope must match the
// deployment scope, so a tenant-scoped file cannot declare one directly.
// Callers deploy this module with scope: managementGroup(<name>) instead.

targetScope = 'managementGroup'

@description('Name of the assignment (callers pass a guid for stability).')
param assignmentName string

@description('Display name of the assignment.')
param displayName string

@description('Full resource ID of the policy definition (built-in or custom).')
param policyDefinitionId string

@description('Enforcement mode: Default (deny) or DoNotEnforce (audit-only).')
param enforcementMode string = 'DoNotEnforce'

@description('Parameters object for the policy definition, e.g. { listOfAllowedLocations: { value: [...] } }. Empty when the definition takes no parameters.')
param policyParameters object = {}

resource assignment 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: assignmentName
  properties: {
    displayName: displayName
    policyDefinitionId: policyDefinitionId
    enforcementMode: enforcementMode
    parameters: policyParameters
  }
}
