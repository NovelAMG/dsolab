# ADR 0007 — Separate "TF runner" and "human admin" principals for Key Vault access

**Status**: Accepted
**Date**: 2026-05-22
**Phase**: 1B (discovered during first apply verification)

## Context

The Key Vault module originally took a single `current_principal_object_id` variable, populated in the env composition as `data.azurerm_client_config.current.object_id`. The intent: "the principal running Terraform always has KV Administrator so it can immediately write secrets."

**The bug**: when Terraform runs in GitHub Actions, `data.azurerm_client_config.current.object_id` is the **GHA managed identity** (`mi-gha-dsolab`), not the human user who triggered the workflow. After CI applied Phase 1B successfully, the human admin had **zero** Key Vault permissions — `az keyvault secret list` returned `ForbiddenByRbac`.

The local-run case worked fine because the same data source returned the human's OID. The CI-run case silently produced a vault only the MI could read.

## Decision

1. Change the Key Vault module's `current_principal_object_id` (single string) → `admin_principal_object_ids` (`list(string)`). Module assigns `Key Vault Administrator` to each principal in the list via `for_each`.
2. In the env composition, build the list as:
   ```hcl
   admin_principal_object_ids = distinct(compact([
     data.azurerm_client_config.current.object_id,
     var.human_admin_object_id,
   ]))
   ```
3. Add `var.human_admin_object_id` (nullable string).
4. Wire it via a GitHub repo variable `HUMAN_ADMIN_OID` (set by the bootstrap script), passed to TF in both workflows as `TF_VAR_human_admin_object_id`.
5. `compact()` drops nulls (so local runs without the variable set still work); `distinct()` de-dupes if the human happens to also be the TF runner.

## Why this is right

- **Deterministic access regardless of runner**: KV access doesn't depend on who happened to run the last `apply`.
- **No least-privilege regression**: the MI still gets KV Administrator (required to write secrets); the human gets it too (required to read them locally).
- **No secret material crosses boundaries**: `HUMAN_ADMIN_OID` is a public OID, not a credential. Stored as a Variable (not Secret) in GitHub.
- **Backward-compatible-ish**: if `human_admin_object_id` is unset, the module still works with only the TF runner — useful for fully unattended pipelines where no human ever needs portal access (a real prod pattern).

## Generalization

This pattern (`distinct(compact([...]))` for principal-OID lists) is reusable. Any future module that grants RBAC to "the principal running TF" should also accept a human admin OID, for the same reason. Candidates in later phases:
- Phase 1D `mi-n8n-aoai` workload identity owners
- Phase 3 admission webhook namespaces
- Phase 6 Sentinel workspace contributors

## Migration note

For Phase 1B's existing deployment, the human admin was granted KV Administrator manually via `az role assignment create` (post-apply). The next CI-run apply (after this fix lands and `HUMAN_ADMIN_OID` is set) will create the same assignment via Terraform — the manual one becomes a no-op duplicate that TF doesn't manage. Either:
- Leave it (harmless), or
- After the fix is applied, run `az role assignment delete ...` to clean up.

This lab leaves it. The duplicate role assignment is invisible in normal usage.
