// Azure Landing Zone in Bicep — CAF-style, ported from the Terraform
// implementation in ../terraform-azure-landing-zone (same architecture,
// expressed with Bicep modules and scopes instead of Terraform providers).
//
// Deployment model:
//   * main.bicep runs at subscription scope and creates three resource groups.
//   * governance.bicep runs at tenant scope (management groups + policy).
//   * networking / monitoring / shared-services / workload-aks run at
//     resource-group scope inside those groups.
// Deploy with:
//   az deployment sub create --location eastus2 \
//     --template-file main.bicep \
//     --parameters environments/dev.bicepparam
// The deploying identity needs Management Group Contributor at the tenant
// root for the governance module, plus Contributor on the three subscriptions.
//
// This design has been compiler-validated only (bicep build + lint). It has
// NOT been deployed to any live tenant. Every subscription ID, Entra group
// object ID, and similar value in the parameters file is a placeholder.

targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'eastus2'

@description('Name of the custom root management group.')
param rootManagementGroupName string = 'alz'

@description('Display name of the custom root management group.')
param rootManagementGroupDisplayName string = 'alz'

@description('Subscription placed under the Connectivity management group (hub networking).')
param connectivitySubscriptionId string

@description('Subscription placed under the Management management group (Log Analytics).')
param managementSubscriptionId string

@description('Subscription placed under the Corp management group (workload landing zones).')
param workloadSubscriptionId string

@description('Subscriptions placed under the Identity management group.')
param identitySubscriptionIds array = []

@description('Subscriptions placed under the Online management group.')
param onlineSubscriptionIds array = []

@description('Regions the Azure Policy guardrail allows.')
param allowedLocations array = [
  'eastus2'
  'centralus'
]

@description('Tag key the Azure Policy guardrail requires on resource groups.')
param requiredTagName string = 'environment'

@description('When true, policy assignments enforce (Deny). When false, they run audit-only (DoNotEnforce) so a new tenant can onboard before enforcement.')
param policyEnforcementEnabled bool = false

@description('Name of the shared Key Vault. Key Vault names are globally unique — pick your own.')
param keyVaultName string = 'kv-alz-shared-dev'

@description('Entra ID group object IDs that administer the AKS cluster. Placeholder values only.')
param aksAdminGroupObjectIds array = []

@description('Tags applied to every taggable resource.')
param tags object = {
  environment: 'dev'
  project: 'azure-bicep-landing-zone'
}

@description('Deploy Azure Bastion in the hub for private, browser-based VM access (no jump-box public IPs).')
param enableBastion bool = true

@description('Azure Firewall SKU tier (Standard or Premium).')
@allowed([
  'Standard'
  'Premium'
])
param firewallSkuTier string = 'Standard'

@description('Kubernetes version for the AKS cluster and node pools.')
param kubernetesVersion string = '1.30'

@description('System node pool sizing (system pods only; user workloads go to the user pool).')
param systemNodePool object = {
  vmSize: 'Standard_D4s_v5'
  nodeCount: 2
  minCount: 1
  maxCount: 3
}

@description('User node pool sizing.')
param userNodePool object = {
  vmSize: 'Standard_D4s_v5'
  nodeCount: 2
  minCount: 1
  maxCount: 5
}

// --- Resource groups ---------------------------------------------------------

resource rgConnectivity 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-connectivity'
  location: location
  tags: tags
}

resource rgManagement 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-management'
  location: location
  tags: tags
}

resource rgWorkload 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-workload'
  location: location
  tags: tags
}

// --- Governance (tenant scope) ----------------------------------------------

module governance 'modules/governance.bicep' = {
  name: 'governance'
  scope: tenant()
  params: {
    rootManagementGroupName: rootManagementGroupName
    rootManagementGroupDisplayName: rootManagementGroupDisplayName
    connectivitySubscriptionIds: [
      connectivitySubscriptionId
    ]
    identitySubscriptionIds: identitySubscriptionIds
    managementSubscriptionIds: [
      managementSubscriptionId
    ]
    corpSubscriptionIds: [
      workloadSubscriptionId
    ]
    onlineSubscriptionIds: onlineSubscriptionIds
    allowedLocations: allowedLocations
    requiredTagName: requiredTagName
    policyEnforcementEnabled: policyEnforcementEnabled
  }
}

// --- Monitoring (management resource group) ----------------------------------

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rgManagement
  params: {
    location: location
    tags: tags
  }
}

// --- Networking (connectivity resource group) --------------------------------

module networking 'modules/networking.bicep' = {
  name: 'networking'
  scope: rgConnectivity
  params: {
    location: location
    tags: tags
    enableBastion: enableBastion
    firewallSkuTier: firewallSkuTier
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// --- Shared services (connectivity resource group) ----------------------------

module sharedServices 'modules/shared-services.bicep' = {
  name: 'shared-services'
  scope: rgConnectivity
  params: {
    location: location
    tags: tags
    keyVaultName: keyVaultName
    hubSubnetId: networking.outputs.sharedServicesSubnetId
    privateDnsZoneIdVault: networking.outputs.privateDnsZoneIdVault
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
  }
}

// --- Workload AKS (workload resource group) -----------------------------------

module workloadAks 'modules/workload-aks.bicep' = {
  name: 'workload-aks'
  scope: rgWorkload
  params: {
    location: location
    tags: tags
    kubernetesVersion: kubernetesVersion
    aksSubnetId: networking.outputs.aksSubnetId
    vnetName: networking.outputs.workloadVnetName
    vnetResourceGroupName: rgConnectivity.name
    routeTableName: networking.outputs.workloadRouteTableName
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    adminGroupObjectIds: aksAdminGroupObjectIds
    systemNodePool: systemNodePool
    userNodePool: userNodePool
  }
}

output managementGroupIds object = governance.outputs.managementGroupIds
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output hubVirtualNetworkId string = networking.outputs.hubVirtualNetworkId
output workloadVirtualNetworkId string = networking.outputs.workloadVirtualNetworkId
output appVirtualNetworkId string = networking.outputs.appVirtualNetworkId
output firewallPrivateIp string = networking.outputs.firewallPrivateIp
output keyVaultUri string = sharedServices.outputs.keyVaultUri
output aksClusterName string = workloadAks.outputs.clusterName
output aksClusterId string = workloadAks.outputs.clusterId
