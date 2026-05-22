# ADR 0002 — Use Terraform (not Bicep) for IaC

**Status**: Accepted
**Date**: 2026-05-22
**Phase**: 1A

## Context

We need an Infrastructure-as-Code tool for the lab. Microsoft's first-party choice is Bicep (which compiles to ARM); the cross-cloud default is Terraform. The lab is Azure-only.

## Decision

Use **Terraform** with `hashicorp/azurerm` + `hashicorp/azuread` + `Azure/azapi` providers. State stored in Azure Storage with **blob-lease state locking** and **Entra-only auth** (`use_azuread_auth = true`, no shared keys).

## Why Terraform over Bicep

- **Three resource planes in one tool**: `azurerm` for ARM resources, `azuread` for Entra app registrations and groups, `azapi` for preview/2025-vintage features the AzureRM provider hasn't caught up to. Bicep can do Entra via `Microsoft.Graph` extensibility but it's newer and less documented.
- **State as a feature, not a side effect**: explicit state file = explicit drift detection, explicit `import`, explicit `replace`. ARM/Bicep relies on the live API as the source of truth, which makes drift harder to spot.
- **Plan output is the DevSecOps moment**: reviewing a `terraform plan` in a PR is the cleanest "this is exactly what will change in cloud" review surface. Bicep's `what-if` exists but its output is noisier and less standard across CI tools.
- **Ecosystem for security scanners**: Checkov, Terrascan, tfsec, MSDO — they all have first-class Terraform support. Bicep support is improving but lags.

## Why NOT Bicep

- This is a learning lab, not a Microsoft-internal product. Tying to first-party tooling has no benefit.
- Bicep + AAD via Microsoft.Graph extension is still preview-ish for some scenarios and adds two extensions to manage.

## Tradeoffs we accept

- New Microsoft Azure services land in Bicep slightly before Terraform's `azurerm` provider (sometimes 1–2 months). Mitigation: use `azapi` provider as the escape hatch for anything not yet in `azurerm`.
- The state file is critical — accidental loss breaks the lab. Mitigation: Storage account has soft delete + versioning enabled (set in 1B Terraform module for the state SA's own management).
