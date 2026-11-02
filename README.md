# Azure Bicep Landing Zone

A Cloud Adoption Framework (CAF) style **Azure Landing Zone written in Bicep**:
management-group governance with Azure Policy guardrails, a hub-and-spoke
network with forced egress through Azure Firewall, centralised logging, a
private-by-default Key Vault, and a **private AKS cluster** as the first
workload landing zone.

This is a port of
[terraform-azure-landing-zone](https://github.com/venkateswarlu429/terraform-azure-landing-zone)
— the same architecture, expressed with Bicep modules and scopes instead of
Terraform providers. Everything is modular: each platform area is a
self-contained module, and `main.bicep` composes them the way a platform
team would run it for real.

> **Status:** configuration is fully `bicep build`- and `bicep lint`-clean
> (Bicep CLI 0.48.1, zero errors and zero warnings, including the dev
> parameters file). It has **not** been deployed to a live tenant — no real
> subscription IDs are committed anywhere; placeholders
> (`00000000-0000-0000-0000-000000000000`) mark every spot that needs a
> real value. Like the Terraform original, this is deployable design, not a
> live deployment.

---

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │        Management group hierarchy           │
                        │  alz                                        │
                        │  ├── platform (connectivity/identity/mgmt)  │
                        │  ├── landing-zones (corp / online)          │
                        │  ├── sandbox                                │
                        │  └── decommissioned                         │
                        │  Azure Policy: allowed locations · require  │
                        │  tag on RGs · deny public IP on NICs (LZ)   │
                        └─────────────────────────────────────────────┘

  ┌──────────────────────────── HUB (10.0.0.0/16) ────────────────────────────┐
  │ AzureFirewallSubnet   Azure Firewall + policy (egress inspection)         │
  │ AzureBastionSubnet    Azure Bastion (private operator access)             │
  │ GatewaySubnet         reserved for VPN/ExpressRoute gateway               │
  │ SharedServicesSubnet  Key Vault ── private endpoint only, RBAC mode       │
  │ Private DNS zones     privatelink: blob · vault · azurecr (linked to all) │
  └──────────▲───────────────────────────────▲────────────────────────────────┘
          peering                           peering        (no spoke ↔ spoke)
  ┌──────────┴───────────────────┐  ┌────────┴──────────────────────────────┐
  │ WORKLOAD SPOKE 10.1.0.0/16   │  │ APP SPOKE 10.2.0.0/16                 │
  │ snet-aks (/20) ─ PRIVATE AKS │  │ snet-app · snet-data · snet-pe        │
  │ snet-app · snet-pe           │  │ (generic app landing zone)            │
  └──────────────────────────────┘  └───────────────────────────────────────┘
     All spoke egress (0.0.0.0/0 and hub-bound) ──UDR──▶ hub Azure Firewall

  Central Log Analytics workspace (management subscription) receives
  diagnostics from: Azure Firewall · Key Vault · AKS control plane + OMS agent
```

## Layout

```
main.bicep                  # subscription scope: 3 resource groups + module wiring
main.bicepparam             # (see environments/dev.bicepparam)
environments/
  dev.bicepparam            # dev parameters — placeholders only, never real IDs
modules/
  governance.bicep          # management groups · policy assignments · subscription placement
  networking.bicep          # hub & spokes · firewall · peerings · routes · private DNS
  monitoring.bicep          # central Log Analytics workspace
  shared-services.bicep     # private Key Vault (+ private endpoint, RBAC, diagnostics)
  workload-aks.bicep        # private AKS cluster (system + user pools, UDR egress)
  policy-assignment.bicep   # management-group-scoped policy assignment (helper)
  aks-network-grants.bicep  # Network Contributor grants for the cluster identity (helper)
```

## Modules and CAF mapping

| Module | What it builds | CAF landing-zone area |
| --- | --- | --- |
| [`modules/governance.bicep`](modules/governance.bicep) | Management-group hierarchy (platform / landing-zones / corp / online / sandbox / decommissioned), subscription placement, Azure Policy assignments using real built-in definitions, audit-only-or-enforce switch | **Enterprise enrolment, identity & governance** — resource hierarchy, policy-as-guardrails |
| [`modules/networking.bicep`](modules/networking.bicep) | Hub VNet (firewall, bastion, gateway, shared-services subnets), two spoke VNets, hub↔spoke peerings (no spoke↔spoke), Azure Firewall + policy (DNS/NTP platform rules, AKS FQDN egress), UDR route tables forcing all spoke egress via the firewall, Private DNS zones (blob/vault/ACR) linked to every VNet | **Network topology & connectivity** — hub-spoke, forced tunnelling, private DNS |
| [`modules/monitoring.bicep`](modules/monitoring.bicep) | Central Log Analytics workspace; every other module streams diagnostics into it | **Management & monitoring** — centralised logging |
| [`modules/shared-services.bicep`](modules/shared-services.bicep) | Key Vault with public access disabled, private endpoint in the hub, RBAC authorisation (no access policies), purge protection + 90-day soft delete, variable-driven data-plane role assignments | **Security & shared platform services** |
| [`modules/workload-aks.bicep`](modules/workload-aks.bicep) | Private AKS cluster (no public API endpoint) in the workload spoke: Azure CNI, system + user node pools with autoscaling and zone spread, `userDefinedRouting` egress, Entra ID + Azure RBAC with local accounts disabled, Policy add-on, Container Insights (OMS agent) to the central workspace, plus the Network Contributor grants the cluster identity needs on the VNet and route table | **Platform automation & DevOps / workload landing zone** |
| [`modules/policy-assignment.bicep`](modules/policy-assignment.bicep) | Single policy assignment at management-group scope (helper — see below) | **Governance helper** |
| [`modules/aks-network-grants.bicep`](modules/aks-network-grants.bicep) | Network Contributor role assignments scoped to the VNet and route table (helper — see below) | **Platform helper** |

## Policy guardrails (governance module)

All three assignments use Microsoft's real built-in policy definitions — no
hand-maintained policy JSON:

| Policy (built-in) | Definition ID | Scope | Effect / parameters |
| --- | --- | --- | --- |
| Allowed locations | `e56962a6-4747-49cd-b67b-bf8b01975c4c` | Custom root MG | Deny outside `allowedLocations` |
| Require a tag on resource groups | `96670d01-0a4d-4649-9c89-2d3abc0a5025` | Custom root MG | Deny RGs missing `requiredTagName` |
| Network interfaces should not have public IPs | `83a86a26-fd1f-447c-b59d-e51f44264114` | Landing Zones MG | Deny (no parameters) |

Scoping is deliberate: the public-IP deny applies to landing zones only,
because platform subscriptions legitimately create public IPs (firewall,
bastion, gateways). Assignments take an `enforce` switch so a new tenant can
onboard in audit-only (`DoNotEnforce`) mode first.

## Design decisions

- **Private AKS, no exceptions.** The API server has no public endpoint;
  `kubectl` works only from peered networks (or via Bastion-connected jump
  hosts). Local accounts are disabled in favour of Entra ID + Azure RBAC.
- **Hub-spoke with forced tunnelling.** Spokes have no direct peering and
  every spoke subnet carries a route table: `0.0.0.0/0` **and** the hub CIDR
  both next-hop to the firewall's private IP, so internet egress *and*
  east-west traffic are inspected in one place. The AKS cluster uses
  `outboundType = userDefinedRouting` to match — which is why the module
  also grants its identity Network Contributor on the VNet and route table.
- **Policy as guardrails, not gates in pipelines.** Region, tagging and
  network-exposure rules are enforced by Azure Policy at the management-group
  scope, so they hold no matter which tool provisions a workload.
- **Private PaaS by default.** Key Vault is reachable only through a private
  endpoint, with RBAC-mode authorisation and purge protection. Private DNS
  zones for Storage, Key Vault and ACR are created centrally and linked to
  all three VNets, so private endpoints resolve consistently everywhere.
- **One logging sink.** A single Log Analytics workspace in the management
  subscription receives firewall, Key Vault and AKS diagnostics — the pattern
  each module implements with `diagnosticSettings`.
- **No real IDs in git.** Subscription IDs, Entra group object IDs and the
  Key Vault name are all placeholders/examples; real values belong in your
  own (git-ignored) `*.local.bicepparam` file.

## Terraform → Bicep mapping

What maps cleanly, and what differs:

| Terraform concept | Bicep equivalent in this repo | Notes |
| --- | --- | --- |
| Module (`modules/*`) | Module (`modules/*.bicep`) | One module per platform area, same boundaries as the original. |
| Provider aliases per subscription | Deployment scopes (`tenant`, `subscription`, `resourceGroup`) | `main.bicep` runs at subscription scope and creates three resource groups; governance runs at tenant scope; the rest run at resource-group scope. No provider blocks. |
| `for_each` over subnets / zones | Bicep `for` loops | Subnets are child resources so their IDs are referenceable; DNS links use one flat loop (3 zones × 3 VNets) with index arithmetic. |
| `terraform.tfvars` | `environments/dev.bicepparam` | Same placeholder discipline; local overrides go in git-ignored `*.local.bicepparam` files. |
| Remote-state backend (`backend.conf`) | None needed | ARM/Bicep deployments are tracked by Azure itself — there is no state file to bootstrap or store. |
| `enforce` flag on policy assignments | `enforcementMode` (`Default` / `DoNotEnforce`) | Same audit-first onboarding behaviour. |
| `azurerm_management_group_policy_assignment` | `policy-assignment.bicep` module | Policy assignments are extension resources: their scope must match the deployment scope, so a tenant-scoped file cannot declare one directly — it deploys through a module scoped to the management group. |
| `azurerm_role_assignment` on the VNet / route table | `aks-network-grants.bicep` module | Same extension-resource rule: the grants deploy through a module scoped to the networking resource group that owns those targets. |
| `terraform validate` + `fmt` / `tflint` / `Checkov` | `bicep build` + `bicep lint` | See Validation below. |
| `azurerm` resource arguments | ARM resource properties | Mostly one-to-one: `dns.proxyEnabled` becomes `dnsSettings.enableProxy`; firewall rule collections become `ruleCollections` with `ruleCollectionType` + `ruleType` (`NetworkRule` / `ApplicationRule`). |

## Deploy

Prerequisites: Azure CLI logged in as an identity that can create management
groups and assignments (typically *Management Group Contributor* at the
tenant root, and *Owner*/*User Access Administrator* for the RBAC
assignments), and three subscriptions (connectivity, management, workload).

1. **Fill in your values:**

   ```bash
   cp environments/dev.bicepparam environments/dev.local.bicepparam
   # edit dev.local.bicepparam: your subscription IDs,
   # Entra group object IDs, and a globally-unique Key Vault name
   ```

2. **Deploy** (the governance module targets the tenant scope, so the
   deploying identity needs tenant-root permissions even though the entry
   point is a subscription deployment):

   ```bash
   az deployment sub create --location eastus2 \
     --template-file main.bicep \
     --parameters environments/dev.local.bicepparam
   ```

3. **Use it:** get AKS credentials with `az aks get-credentials` from a
   machine inside the peered network (the API server is private), and grant
   the kubelet identity (`kubeletIdentityObjectId` output) `AcrPull` when
   you add a registry.

## Validation

Validated with Bicep CLI 0.48.1 (installed from the official Bicep release
for this build):

- `bicep build main.bicep` — clean, zero errors, zero warnings.
- `bicep build` on every module individually (`governance`, `networking`,
  `monitoring`, `shared-services`, `workload-aks`, `policy-assignment`,
  `aks-network-grants`) — clean, zero errors, zero warnings.
- `bicep lint main.bicep` — clean, zero warnings.
- `bicep build-params environments/dev.bicepparam` — clean.

What was **not** validated or run:

- No deployment to any live tenant, subscription, or resource group
  (`az deployment` / `what-if` were not run — there are no credentials for
  a tenant here). Compile-clean is not deploy-proven: API versions,
  policy parameters, and cross-scope module wiring should get a
  `what-if` pass against a real tenant before a first apply.
- No live AKS, firewall, or Key Vault behaviour was exercised; node-pool
  VM sizes, Kubernetes version `1.30`, and address spaces are dev defaults
  carried over from the Terraform original, not tuned to a real tenant.

## Identity note

The AKS module configures Entra ID + Azure RBAC integration in code (admin
group object IDs arrive as parameters, local accounts are disabled) and
enables the OIDC issuer. That is the extent of the identity claim in this
repository: configuring the integration in code is not the same as
administering Entra ID, and no Entra administration experience is claimed
here.

## Limitations & next steps

- Not deployed to a live tenant from this repo (no credentials) — `what-if`
  and `apply` behaviour is untested here; build and lint are green.
- `GatewaySubnet` is reserved but no VPN/ExpressRoute gateway is deployed;
  enabling one means flipping the gateway-transit flags in the peerings.
- Natural extensions: Azure Container Registry with private endpoint +
  `AcrPull` for the kubelet identity (the `acr` Private DNS zone is already
  linked), Azure Policy *initiatives* (e.g. the AKS baseline) alongside the
  individual assignments, and a `prod` parameters file reusing the same
  modules with larger address spaces and node pools.

## License

MIT — © 2026 Venkateswarlu Maddula. See [LICENSE](LICENSE).
