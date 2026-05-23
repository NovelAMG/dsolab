# ADR 0009 — Manage Entra app registrations via bootstrap, not Terraform

**Status**: Accepted
**Date**: 2026-05-23
**Phase**: 1D

## Context

Phase 1D needs two Microsoft Entra ID app registrations:

1. **`n8n-api-dsolab`** — represents the n8n agent's API. Exposes a custom OAuth 2.0 scope `access_as_user`. Identifier URI is `api://{appId}` (the only format universally allowed under modern Entra tenant policy `identifierUriAddingDisabled`, which blocks arbitrary URIs like `api://n8n-dsolab`). Used by `oauth2-proxy` as the audience to validate bearer tokens against.
2. **`spa-dsolab`** — represents the chat web UI (the SPA from Phase 1E). Type "Single Page Application" (PKCE). Has delegated permission to call `n8n-api-dsolab/access_as_user`. Also needs Microsoft Graph `User.Read` for sign-in.

Two ways to create these:

| Option | Mechanism | Permissions needed |
|---|---|---|
| **A. Terraform `azuread` provider** | TF resources `azuread_application`, `azuread_service_principal`, `azuread_application_pre_authorized`, `azuread_service_principal_delegated_permission_grant` | The GitHub Actions MI needs Microsoft Graph `Application.ReadWrite.All` (or `Application.ReadWrite.OwnedBy`) **as an Application permission**. Granting that requires **Global Administrator**. |
| **B. Bootstrap script (`az ad` CLI)** | Shell script run by the human admin | The human's existing **Application Administrator** role is enough. No GA needed. |

## Decision

Use **Option B**: create both Entra app registrations via a new bootstrap script `scripts/02-create-entra-apps.sh`, run once by the human admin (the same person who runs `00-bootstrap-state.sh`).

The script writes the resulting app IDs + Application ID URI to **GitHub repo variables** (`SPA_APP_ID`, `N8N_API_APP_ID`, `N8N_API_APP_URI`). Terraform reads them via the workflow's `TF_VAR_*` env vars and surfaces them as `terraform output` values for Phase 1E's SPA build config.

## Why this is right (consistent with ADR 0008's pattern)

- **Avoids Global Admin requirement**: granting the GHA MI `Application.ReadWrite.*` Microsoft Graph application permission requires Global Administrator consent in Entra. Our entire lab is designed around Application Administrator-only access (per the v2 plan). Adding a GA dependency just for two app regs is a regression.
- **Avoids chicken-and-egg with the MI itself**: if Terraform could delete/recreate the MI's own Graph permission grant (it can't, easily, but the pattern would be fragile), recovery would require out-of-band intervention. Same lesson as ADR 0008 for KV admin.
- **App regs are stable lab fixtures**: created once, never refactored. Bootstrap is the right home for things that don't change.
- **Mirrors ADR 0008**: KV admin role assignments live in bootstrap (`00-bootstrap-state.sh`). Entra app registrations now live in bootstrap (`02-create-entra-apps.sh`). Both follow the rule: **identity primitives that grant the TF runner its own permissions belong in bootstrap, not in TF**.

## What stays in Terraform

The **workload identity** for n8n (`mi-n8n-aoai-dsolab` + federated credential + AOAI role assignment) stays Terraform-managed. The MI doesn't grant the TF runner anything — TF creates it from scratch, owns its full lifecycle, and there's no recursive dependency.

| Resource | Where managed | Why |
|---|---|---|
| `mi-n8n-aoai-dsolab` (UAMI for n8n pod) | Terraform (`modules/identity/`) | No cyclic dependency; standard pattern |
| AKS-OIDC federated credential on the UAMI | Terraform | Same |
| `Cognitive Services OpenAI User` role on AOAI | Terraform | Same |
| `n8n-api-dsolab` (Entra app reg) | Bootstrap (`02-create-entra-apps.sh`) | App reg creation needs Graph perms |
| `spa-dsolab` (Entra app reg) | Bootstrap | Same |
| Admin consent on SPA → n8n-api scope | Bootstrap (`az ad app permission admin-consent`) | Requires Cloud Application Administrator |

## How the lab consumes the app IDs

After `02-create-entra-apps.sh` runs:
- The script sets `SPA_APP_ID`, `N8N_API_APP_ID`, `N8N_API_APP_URI` as GitHub repo Variables.
- The `tf-plan.yml` and `tf-apply.yml` workflows pass them to Terraform as `TF_VAR_spa_app_id`, `TF_VAR_n8n_api_app_id`, `TF_VAR_n8n_api_app_uri`.
- The env composition declares these as variables (nullable) and surfaces them in `terraform output`.
- Phase 1E reads `terraform output spa_app_id` to populate the SPA's MSAL config; reads `n8n_api_app_uri` to configure oauth2-proxy.

## Re-runs

The script is idempotent — re-running it detects existing app regs by display name and reuses them. Safe to run multiple times during development.

## Tradeoff

We lose `terraform plan` visibility into the app reg state. To audit what's in the app registrations, you'd open the Entra admin center, not look at a TF plan output. For two stable app regs that change rarely, this is an acceptable cost.
