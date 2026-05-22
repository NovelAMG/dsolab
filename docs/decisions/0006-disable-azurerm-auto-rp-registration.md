# ADR 0006 — Disable AzureRM provider auto-registration of Resource Providers

**Status**: Accepted
**Date**: 2026-05-22
**Phase**: 1B (discovered during first Terraform plan run)

## Context

By default, the `hashicorp/azurerm` v4 provider attempts to **auto-register every Azure Resource Provider it supports** (~70 RPs: ServiceBus, Databricks, AppConfig, RecoveryServices, etc.) the first time it runs against a subscription. Registration is a subscription-scope action (`Microsoft.<RP>/register/action` at `/subscriptions/<id>`).

Our GitHub Actions managed identity (`mi-gha-dsolab`) is scoped to **Contributor on `rg-dsolab-sea` only** — not on the subscription. This is intentional, per least-privilege.

Result: first `terraform plan` in CI fails with 60+ `AuthorizationFailed: ... does not have authorization to perform action 'Microsoft.<RP>/register/action'` errors, even though we only use ~13 of those RPs.

## Decision

In `terraform/envs/lab/providers.tf`, set:

```hcl
provider "azurerm" {
  resource_provider_registrations = "none"
  ...
}
```

Pre-register the RPs we actually need via `scripts/01-register-resource-providers.sh`, which is a one-time subscription-scope operation run by a human Owner (the same person who ran the Phase 1A bootstrap script).

## RPs registered

| RP | Used by |
|---|---|
| `Microsoft.ContainerService` | AKS module |
| `Microsoft.ContainerRegistry` | ACR module |
| `Microsoft.KeyVault` | KV module |
| `Microsoft.OperationalInsights` | Log Analytics module |
| `Microsoft.Insights` | Diagnostic settings, metrics |
| `Microsoft.CognitiveServices` | Azure OpenAI module |
| `Microsoft.DBforPostgreSQL` | Postgres Flex module |
| `Microsoft.ManagedIdentity` | User-assigned MIs (1A, 1D) |
| `Microsoft.Network` | AKS managed VNet, future private endpoints |
| `Microsoft.Compute` | AKS VMSS nodes |
| `Microsoft.Storage` | Azure Files for AKS PVCs (1E) |
| `Microsoft.Authorization` | Role assignments |
| `Microsoft.PolicyInsights` | Defender posture findings (2A.1) |

## Why this is the right call

- **Least-privilege intact**: the CI MI keeps RG-scoped Contributor, no subscription-scope perms.
- **Explicit registration list** = audit trail of every RP this lab depends on (visible in `scripts/01-register-resource-providers.sh`).
- **Future RP additions are deliberate**: adding a new module that needs an unregistered RP fails cleanly with a clear error, prompting an ADR-worthy decision and a one-line script addition.

## Tradeoffs

- One extra one-time setup step per subscription (the script).
- If a future module silently adds a dependency on a new RP, the apply fails with `ResourceProviderNotRegistered` — easy to fix (`az provider register --namespace ...` + add to the script), but it's a real failure mode to know about.
- This script is the **only** thing that needs a subscription-scope Owner. The Phase 1A bootstrap also needed it for role assignments. Both run by the same human, same session, same blast radius.
