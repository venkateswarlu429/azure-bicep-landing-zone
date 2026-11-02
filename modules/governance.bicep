// Governance — CAF management-group hierarchy, Azure Policy guardrails.
//
// Mirrors Microsoft's Cloud Adoption Framework enterprise-scale reference
// architecture (same shape as the Terraform original):
//
//   Tenant Root
//   └── alz                       <- custom root created by this module
//       ├── platform
//       │   ├── connectivity      <- hub networking subscription
//       │   ├── identity
//       │   └── management        <- Log Analytics subscription
//       ├── landing-zones
//       │   ├── corp              <- private/internal workloads (AKS spoke)
//       │   └── online            <- internet-facing workloads
//       ├── sandbox
//       └── decommissioned
//
// Policy guardrails use Microsoft's real built-in definitions — no custom
// policy JSON is maintained. Assignments take an enforcement switch so a new
// tenant can onboard in audit-only (DoNotEnforce) mode first.

targetScope = 'tenant'

@description('Name of the custom root management group.')
param rootManagementGroupName string = 'alz'

@description('Display name of the custom root management group.')
param rootManagementGroupDisplayName string = 'alz'

@description('Subscriptions placed under the Connectivity management group.')
param connectivitySubscriptionIds array = []

@description('Subscriptions placed under the Identity management group.')
param identitySubscriptionIds array = []

@description('Subscriptions placed under the Management management group.')
param managementSubscriptionIds array = []

@description('Subscriptions placed under the Corp management group.')
param corpSubscriptionIds array = []

@description('Subscriptions placed under the Online management group.')
param onlineSubscriptionIds array = []

@description('Regions the Allowed-locations guardrail permits.')
param allowedLocations array = [
  'eastus2'
  'centralus'
]

@description('Tag key the Require-a-tag guardrail enforces on resource groups.')
param requiredTagName string = 'environment'

@description('When true, assignments enforce (Deny). When false, audit-only (DoNotEnforce).')
param policyEnforcementEnabled bool = false

var enforcementMode = policyEnforcementEnabled ? 'Default' : 'DoNotEnforce'

// --- Management group hierarchy ----------------------------------------------

resource root 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: rootManagementGroupName
  properties: {
    displayName: rootManagementGroupDisplayName
    details: {
      parent: {
        id: tenantResourceId('Microsoft.Management/managementGroups', tenant().tenantId)
      }
    }
  }
}

resource platform 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'platform'
  properties: {
    displayName: 'Platform'
    details: {
      parent: {
        id: root.id
      }
    }
  }
}

resource connectivity 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'connectivity'
  properties: {
    displayName: 'Connectivity'
    details: {
      parent: {
        id: platform.id
      }
    }
  }
}

resource identity 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'identity'
  properties: {
    displayName: 'Identity'
    details: {
      parent: {
        id: platform.id
      }
    }
  }
}

resource management 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'management'
  properties: {
    displayName: 'Management'
    details: {
      parent: {
        id: platform.id
      }
    }
  }
}

resource landingZones 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'landing-zones'
  properties: {
    displayName: 'Landing Zones'
    details: {
      parent: {
        id: root.id
      }
    }
  }
}

resource corp 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'corp'
  properties: {
    displayName: 'Corp'
    details: {
      parent: {
        id: landingZones.id
      }
    }
  }
}

resource online 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'online'
  properties: {
    displayName: 'Online'
    details: {
      parent: {
        id: landingZones.id
      }
    }
  }
}

resource sandbox 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'sandbox'
  properties: {
    displayName: 'Sandbox'
    details: {
      parent: {
        id: root.id
      }
    }
  }
}

resource decommissioned 'Microsoft.Management/managementGroups@2021-04-01' = {
  name: 'decommissioned'
  properties: {
    displayName: 'Decommissioned'
    details: {
      parent: {
        id: root.id
      }
    }
  }
}

// --- Subscription placement ---------------------------------------------------
// Each association files one subscription under its management group. Empty
// input arrays emit no associations, so the hierarchy deploys cleanly before
// any subscription is filed under it.

resource connectivitySubs 'Microsoft.Management/managementGroups/subscriptions@2020-05-01' = [
  for subId in connectivitySubscriptionIds: {
    parent: connectivity
    name: subId
  }
]

resource identitySubs 'Microsoft.Management/managementGroups/subscriptions@2020-05-01' = [
  for subId in identitySubscriptionIds: {
    parent: identity
    name: subId
  }
]

resource managementSubs 'Microsoft.Management/managementGroups/subscriptions@2020-05-01' = [
  for subId in managementSubscriptionIds: {
    parent: management
    name: subId
  }
]

resource corpSubs 'Microsoft.Management/managementGroups/subscriptions@2020-05-01' = [
  for subId in corpSubscriptionIds: {
    parent: corp
    name: subId
  }
]

resource onlineSubs 'Microsoft.Management/managementGroups/subscriptions@2020-05-01' = [
  for subId in onlineSubscriptionIds: {
    parent: online
    name: subId
  }
]

// --- Policy guardrails (built-in definitions) ---------------------------------
// Policy assignments are extension resources scoped to a management group,
// which differs from this file's tenant scope — so each assignment deploys
// through the policy-assignment module scoped to its management group.

module allowedLocationsAssignment 'policy-assignment.bicep' = {
  name: 'policy-allowed-locations'
  scope: managementGroup(root.name)
  params: {
    assignmentName: guid(root.id, 'allowed-locations')
    displayName: 'Allowed locations for resources'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
    enforcementMode: enforcementMode
    policyParameters: {
      listOfAllowedLocations: {
        value: allowedLocations
      }
    }
  }
}

module requireTagAssignment 'policy-assignment.bicep' = {
  name: 'policy-require-tag'
  scope: managementGroup(root.name)
  params: {
    assignmentName: guid(root.id, 'require-tag-on-rg')
    displayName: 'Require a tag on resource groups'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025'
    enforcementMode: enforcementMode
    policyParameters: {
      tagName: {
        value: requiredTagName
      }
    }
  }
}

// Scoping is deliberate: the public-IP deny applies to landing zones only,
// because platform subscriptions legitimately create public IPs (firewall,
// bastion, gateways).
module denyPublicIpAssignment 'policy-assignment.bicep' = {
  name: 'policy-deny-public-ip'
  scope: managementGroup(landingZones.name)
  params: {
    assignmentName: guid(landingZones.id, 'deny-public-ip-on-nic')
    displayName: 'Network interfaces should not have public IPs'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114'
    enforcementMode: enforcementMode
    policyParameters: {}
  }
}

output managementGroupIds object = {
  root: root.id
  platform: platform.id
  connectivity: connectivity.id
  identity: identity.id
  management: management.id
  landingZones: landingZones.id
  corp: corp.id
  online: online.id
  sandbox: sandbox.id
  decommissioned: decommissioned.id
}
