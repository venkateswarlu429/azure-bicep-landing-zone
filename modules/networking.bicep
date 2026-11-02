// Networking — hub-and-spoke topology (connectivity resource group).
//
//   ┌──────────────────────────── HUB ────────────────────────────┐
//   │ AzureFirewallSubnet │ AzureBastionSubnet │ GatewaySubnet    │
//   │ SharedServicesSubnet (shared services + private endpoints)  │
//   └───────▲───────────────────────────────▲─────────────────────┘
//        peering                         peering        (no spoke <-> spoke)
//   ┌───────┴──────────────┐        ┌───────┴─────────────────────┐
//   │ WORKLOAD SPOKE       │        │ APP SPOKE                   │
//   │ snet-aks (AKS)       │        │ snet-app / snet-data        │
//   │ snet-app, snet-pe    │        │ snet-private-endpoints      │
//   └─────────────────────┘        └─────────────────────────────┘
//
// All spoke egress (internet AND cross-spoke) is forced through the hub
// Azure Firewall by user-defined routes. Peering is hub<->spoke only, so
// spokes are isolated from each other by design.
//
// Subnets are child resources (not inline arrays) so the firewall, Bastion,
// private endpoints, and the AKS module can reference their IDs directly.
// Route tables are associated with every spoke subnet — the AKS subnet
// association is load-bearing: the AKS cluster uses outbound type
// userDefinedRouting, which requires a 0.0.0.0/0 route on the node subnet.

targetScope = 'resourceGroup'

@description('Azure region for all networking resources.')
param location string

@description('Tags applied to every taggable resource.')
param tags object = {}

@description('Deploy Azure Bastion in the hub for private, browser-based VM access (no jump-box public IPs).')
param enableBastion bool = true

@description('Azure Firewall SKU tier (Standard or Premium).')
@allowed([
  'Standard'
  'Premium'
])
param firewallSkuTier string = 'Standard'

@description('Resource ID of the central Log Analytics workspace for firewall diagnostics.')
param logAnalyticsWorkspaceId string

@description('Hub address space.')
param hubAddressSpace array = [
  '10.0.0.0/16'
]

@description('Workload (AKS) spoke address space.')
param workloadSpokeAddressSpace array = [
  '10.1.0.0/16'
]

@description('Application spoke address space.')
param appSpokeAddressSpace array = [
  '10.2.0.0/16'
]

// --- Virtual networks ---------------------------------------------------------

resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-hub'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: hubAddressSpace
    }
  }
}

resource workloadVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-spoke-workload'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: workloadSpokeAddressSpace
    }
  }
}

resource appVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-spoke-app'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: appSpokeAddressSpace
    }
  }
}

// --- Hub subnets (AzureFirewallSubnet, AzureBastionSubnet and GatewaySubnet
// must keep those exact names — Azure requires them) ---------------------------

resource snetFirewall 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: hubVnet
  name: 'AzureFirewallSubnet'
  properties: {
    addressPrefix: '10.0.1.0/26'
  }
}

resource snetBastion 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: hubVnet
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: '10.0.2.0/26'
  }
}

resource snetGateway 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: hubVnet
  name: 'GatewaySubnet'
  properties: {
    addressPrefix: '10.0.3.0/27'
  }
}

resource snetSharedServices 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: hubVnet
  name: 'SharedServicesSubnet'
  properties: {
    addressPrefix: '10.0.4.0/24'
  }
}

// --- Azure Firewall (the single egress/inspection point) ----------------------

resource pipFirewall 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-azfw-hub'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'azfw-policy-hub'
  location: location
  tags: tags
  properties: {
    sku: {
      tier: firewallSkuTier
    }
    threatIntelMode: 'Alert'
    dnsSettings: {
      enableProxy: true
    }
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'azfw-hub'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: firewallSkuTier
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: snetFirewall.id
          }
          publicIPAddress: {
            id: pipFirewall.id
          }
        }
      }
    ]
    firewallPolicy: {
      id: firewallPolicy.id
    }
  }
}

// Firewall policy rules: platform plumbing (DNS, NTP) every workload needs,
// plus the documented minimum AKS control-plane and image-pull endpoints.
// A private cluster still needs outbound access to its region-scoped
// *.azmk8s.io endpoints.
resource firewallRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: firewallPolicy
  name: 'spoke-egress'
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'allow-platform-services'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            name: 'allow-dns'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'UDP'
              'TCP'
            ]
            sourceAddresses: concat(workloadSpokeAddressSpace, appSpokeAddressSpace)
            destinationAddresses: [
              '168.63.129.16'
            ]
            destinationPorts: [
              '53'
            ]
          }
          {
            name: 'allow-ntp'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'UDP'
            ]
            sourceAddresses: concat(workloadSpokeAddressSpace, appSpokeAddressSpace)
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '123'
            ]
          }
        ]
      }
      {
        name: 'allow-aks-egress'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            name: 'aks-required-fqdns'
            ruleType: 'ApplicationRule'
            sourceAddresses: workloadSpokeAddressSpace
            targetFqdns: [
              '*.hcp.${location}.azmk8s.io'
              '*.tun.${location}.azmk8s.io'
              'mcr.microsoft.com'
              '*.data.mcr.microsoft.com'
              // These two are the documented public-Azure AKS egress endpoints.
              #disable-next-line no-hardcoded-env-urls
              'management.azure.com'
              #disable-next-line no-hardcoded-env-urls
              'login.microsoftonline.com'
              'packages.microsoft.com'
              'acs-mirror.azureedge.net'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
          }
        ]
      }
    ]
  }
}

// --- Forced tunnelling: spoke route tables via the firewall --------------------

resource rtWorkload 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-spoke-workload'
  location: location
  tags: tags
  properties: {
    routes: [
      {
        name: 'default-via-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
      {
        name: 'hub-via-firewall'
        properties: {
          addressPrefix: hubAddressSpace[0]
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

resource rtApp 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-spoke-app'
  location: location
  tags: tags
  properties: {
    routes: [
      {
        name: 'default-via-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
      {
        name: 'hub-via-firewall'
        properties: {
          addressPrefix: hubAddressSpace[0]
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

// --- Spoke subnets (all carry the firewall route table) ------------------------
// The AKS subnet is sized /20 because Azure CNI consumes one IP per pod.

resource snetAks 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: workloadVnet
  name: 'snet-aks'
  properties: {
    addressPrefix: '10.1.0.0/20'
    routeTable: {
      id: rtWorkload.id
    }
  }
}

resource snetWorkloadApp 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: workloadVnet
  name: 'snet-app'
  properties: {
    addressPrefix: '10.1.16.0/24'
    routeTable: {
      id: rtWorkload.id
    }
  }
}

resource snetWorkloadPe 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: workloadVnet
  name: 'snet-private-endpoints'
  properties: {
    addressPrefix: '10.1.17.0/24'
    routeTable: {
      id: rtWorkload.id
    }
  }
}

resource snetAppApp 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: appVnet
  name: 'snet-app'
  properties: {
    addressPrefix: '10.2.0.0/24'
    routeTable: {
      id: rtApp.id
    }
  }
}

resource snetAppData 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: appVnet
  name: 'snet-data'
  properties: {
    addressPrefix: '10.2.1.0/24'
    routeTable: {
      id: rtApp.id
    }
  }
}

resource snetAppPe 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: appVnet
  name: 'snet-private-endpoints'
  properties: {
    addressPrefix: '10.2.2.0/24'
    routeTable: {
      id: rtApp.id
    }
  }
}

// --- Hub <-> spoke peerings (no spoke <-> spoke peering, by design) ------------

resource peeringHubToWorkload 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: 'hub-to-workload'
  properties: {
    remoteVirtualNetwork: {
      id: workloadVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peeringWorkloadToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: workloadVnet
  name: 'workload-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peeringHubToApp 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: 'hub-to-app'
  properties: {
    remoteVirtualNetwork: {
      id: appVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource peeringAppToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: appVnet
  name: 'app-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// --- Azure Bastion (optional) --------------------------------------------------

resource pipBastion 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (enableBastion) {
  name: 'pip-bastion-hub'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = if (enableBastion) {
  name: 'bastion-hub'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: snetBastion.id
          }
          publicIPAddress: {
            id: pipBastion.id
          }
        }
      }
    ]
  }
}

// --- Private DNS for Azure Private Link ---------------------------------------
// Private endpoints only stay private if every VNet resolves the service's
// privatelink zone to the endpoint IP. Zones are created once in the hub
// and linked to the hub and BOTH spokes, so a private endpoint created in
// any of them resolves consistently across the estate.
//   blob  -> privatelink.blob.core.windows.net   (Storage)
//   vault -> privatelink.vaultcore.azure.net     (Key Vault — used by the
//                                                 shared-services module)
//   acr   -> privatelink.azurecr.io              (Container Registry)

var dnsZones = [
  {
    key: 'blob'
    name: 'privatelink.blob.${environment().suffixes.storage}'
  }
  {
    key: 'vault'
    name: 'privatelink.vaultcore.azure.net'
  }
  {
    key: 'acr'
    name: 'privatelink.azurecr.io'
  }
]

var linkVnets = [
  {
    key: 'hub'
    id: hubVnet.id
  }
  {
    key: 'workload'
    id: workloadVnet.id
  }
  {
    key: 'app'
    id: appVnet.id
  }
]

resource dnsZoneResources 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for z in dnsZones: {
    name: z.name
    location: 'global'
    tags: tags
  }
]

// One link per (zone, VNet) pair: 3 zones x 3 VNets. Index arithmetic keeps
// the loop flat: zone = i / 3, VNet = i % 3.
resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for i in range(0, length(dnsZones) * length(linkVnets)): {
    name: '${dnsZones[i / length(linkVnets)].name}/${dnsZones[i / length(linkVnets)].key}-${linkVnets[i % length(linkVnets)].key}'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: linkVnets[i % length(linkVnets)].id
      }
      registrationEnabled: false
    }
  }
]

// --- Firewall diagnostics to the central workspace ------------------------------

resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-azfw-hub'
  scope: firewall
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'AzureFirewallApplicationRule'
        enabled: true
      }
      {
        category: 'AzureFirewallNetworkRule'
        enabled: true
      }
      {
        category: 'AzureFirewallDnsProxy'
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

output hubVirtualNetworkId string = hubVnet.id
output workloadVirtualNetworkId string = workloadVnet.id
output workloadVnetName string = workloadVnet.name
output appVirtualNetworkId string = appVnet.id
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output aksSubnetId string = snetAks.id
output sharedServicesSubnetId string = snetSharedServices.id
output workloadRouteTableId string = rtWorkload.id
output workloadRouteTableName string = rtWorkload.name
output privateDnsZoneIdVault string = dnsZoneResources[1].id
output privateDnsZoneIdBlob string = dnsZoneResources[0].id
output privateDnsZoneIdAcr string = dnsZoneResources[2].id
