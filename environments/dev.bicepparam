// Dev environment parameters for main.bicep.
//
// Copy this file for a new environment and replace EVERY placeholder with
// real values. This committed copy contains placeholders only — no real
// subscription IDs, tenant IDs, or Entra group object IDs. Never commit a
// copy with real IDs in it; keep environment-specific values in your own
// (git-ignored) *.local.bicepparam file instead.

using '../main.bicep'

param location = 'eastus2'

// Subscriptions (replace the placeholder GUIDs with your tenant's):
param connectivitySubscriptionId = '00000000-0000-0000-0000-000000000000'
param managementSubscriptionId = '00000000-0000-0000-0000-000000000000'
param workloadSubscriptionId = '00000000-0000-0000-0000-000000000000'

// Regions the Azure Policy guardrail will allow:
param allowedLocations = [
  'eastus2'
  'centralus'
]

// Key Vault names are globally unique — pick your own:
param keyVaultName = 'kv-alz-shared-dev'

// Entra ID group that should administer the AKS cluster (placeholder):
param aksAdminGroupObjectIds = [
  '00000000-0000-0000-0000-000000000000'
]

// Audit-only policy enforcement for first onboarding (flip to true to deny):
param policyEnforcementEnabled = false
