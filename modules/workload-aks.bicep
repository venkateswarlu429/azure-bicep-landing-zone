// Workload AKS — private AKS cluster in the workload spoke.
//
// Private control plane, no public API endpoint, Azure CNI, system + user
// node pools with autoscaling and zone spread, user-defined-routing egress
// (all cluster egress goes through the hub firewall — the node subnet's
// route table is associated by the networking module), and Container
// Insights streaming to the central workspace with the Policy add-on.
//
// Identity note, stated precisely: the cluster module configures Entra ID +
// Azure RBAC integration in code (admin group object IDs are parameters,
// local accounts are disabled) and enables the OIDC issuer. That is the
// extent of the identity claim here — this module does not administer
// Entra ID itself, and no Entra administration experience is claimed
// anywhere in this repository.
//
// The cluster identity also needs Network Contributor on the VNet and on
// the spoke route table (UDR clusters require it). Those grants deploy
// through the aks-network-grants module, scoped to the networking resource
// group that owns both targets.

targetScope = 'resourceGroup'

@description('Azure region for the cluster.')
param location string

@description('Tags applied to the cluster.')
param tags object = {}

@description('Cluster name (also used as the DNS prefix).')
param clusterName string = 'aks-workload'

@description('Kubernetes version for the cluster and node pools.')
param kubernetesVersion string = '1.30'

@description('Resource ID of the AKS node subnet (snet-aks in the workload spoke).')
param aksSubnetId string

@description('Name of the workload spoke VNet (for the Network Contributor grant).')
param vnetName string

@description('Resource group containing the workload spoke VNet and route table.')
param vnetResourceGroupName string

@description('Name of the workload spoke route table (for the Network Contributor grant).')
param routeTableName string

@description('Resource ID of the central Log Analytics workspace for Container Insights and control-plane diagnostics.')
param logAnalyticsWorkspaceId string

@description('Entra ID group object IDs that administer the cluster. Placeholder values only.')
param adminGroupObjectIds array = []

@description('System node pool sizing (system pods only).')
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

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: clusterName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: clusterName
    disableLocalAccounts: true
    apiServerAccessProfile: {
      enablePrivateCluster: true
      enablePrivateClusterPublicFQDN: false
    }
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: adminGroupObjectIds
    }
    oidcIssuerProfile: {
      enabled: true
    }
    networkProfile: {
      networkPlugin: 'azure'
      loadBalancerSku: 'standard'
      outboundType: 'userDefinedRouting'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        vmSize: systemNodePool.vmSize
        count: systemNodePool.nodeCount
        enableAutoScaling: true
        minCount: systemNodePool.minCount
        maxCount: systemNodePool.maxCount
        availabilityZones: [
          '1'
          '2'
          '3'
        ]
        osDiskSizeGB: 128
        vnetSubnetID: aksSubnetId
      }
      {
        name: 'user'
        mode: 'User'
        vmSize: userNodePool.vmSize
        count: userNodePool.nodeCount
        enableAutoScaling: true
        minCount: userNodePool.minCount
        maxCount: userNodePool.maxCount
        availabilityZones: [
          '1'
          '2'
          '3'
        ]
        osDiskSizeGB: 128
        vnetSubnetID: aksSubnetId
      }
    ]
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
        }
      }
      azurepolicy: {
        enabled: true
      }
    }
  }
}

// Control-plane diagnostics to the central workspace (Container Insights
// itself arrives via the omsagent add-on above).
resource aksDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${clusterName}'
  scope: aks
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'kube-apiserver'
        enabled: true
      }
      {
        category: 'kube-controller-manager'
        enabled: true
      }
      {
        category: 'kube-scheduler'
        enabled: true
      }
      {
        category: 'kube-audit'
        enabled: true
      }
      {
        category: 'cluster-autoscaler'
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

// Network Contributor (4d97b98b-1d4f-4787-a291-c67834d212) for the cluster
// identity, scoped to the VNet and to the spoke route table. Role
// assignments are extension resources, so they deploy through a module
// scoped to the networking resource group that owns those targets.
module networkGrants 'aks-network-grants.bicep' = {
  name: 'aks-network-grants'
  scope: resourceGroup(vnetResourceGroupName)
  params: {
    vnetName: vnetName
    routeTableName: routeTableName
    principalId: aks.identity.principalId
  }
}

output clusterName string = aks.name
output clusterId string = aks.id
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output kubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
