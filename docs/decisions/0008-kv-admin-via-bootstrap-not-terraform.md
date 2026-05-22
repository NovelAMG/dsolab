# ADR 0008 — Manage Key Vault Administrator role assignments via bootstrap, not Terraform

**Status**: Accepted (supersedes ADR 0007)
**Date**: 2026-05-23
**Phase**: 1B.2 (discovered during 1B.1 apply failure)

## Context

ADR 0007 introduced a `for_each` role assignment in the Key Vault module to grant `Key Vault Administrator` to both the Terraform runner and a designated human admin. Sound in theory.

In practice, applying that refactor on a live deployment caused a **chicken-and-egg deadlock**:

1. The previous apply had a single `azurerm_role_assignment.current_principal_kv_admin` granting the MI access. Existed in state + in Azure.
2. The 1B.1 apply planned: destroy the singleton, create two new `for_each` entries (`kv_admin["mi_oid"]`, `kv_admin["human_oid"]`).
3. During apply, the destroy succeeded first → MI lost KV access.
4. The two creates failed with HTTP 409 `RoleAssignmentExists` because a manual role assignment for the human user (created out-of-band the previous day) was already at the same scope+role+principal triplet.
5. Subsequent applies failed during the **read phase** because TF needed `getSecret` to refresh `azurerm_key_vault_secret` resources in state, but the MI had no KV access.

Even deleting all role assignments at the KV scope didn't help — the read phase still failed because plan requires MI to have permission to query existing secrets in state.

## Decision

**Remove `Key Vault Administrator` role assignment from Terraform entirely.** Grant it at **resource group scope** via `scripts/00-bootstrap-state.sh` to:

- The GitHub Actions MI (`mi-gha-dsolab`) — already gets `Contributor` + `User Access Administrator` on the RG by the bootstrap; we add `Key Vault Administrator` to the list.
- The current logged-in user (the human admin running bootstrap) — same.

RG scope is broader than necessary (it covers any KV created in that RG, not just `kv-dsolab-sea-xsqb`), but for a single-RG lab this is acceptable and lets the lab create additional KVs later without further bootstrap runs.

## Why this is right

- **No deadlock possible**: KV admin role exists at RG scope before any KV is ever created. `terraform apply` never destroys/recreates the role assignment, so the MI's KV access is always stable.
- **Bootstrap is the right home for identity perms**: bootstrap already handles MI creation, federated credentials, Contributor on RG, UAA on RG, Blob Data Contributor on the state container. Adding `Key Vault Administrator` to this list is consistent with the model: **identity setup is bootstrap-managed, resource topology is Terraform-managed**.
- **Cleaner separation of concerns**: Terraform manages "what exists" (the KV, the secrets); bootstrap manages "who can access" (RBAC on identities). When these two lifecycles get tangled in Terraform, refactoring the access model becomes a high-risk change.

## Tradeoff vs the ADR 0007 attempt

ADR 0007 wanted KV admin grants to be visible in `terraform plan` output (auditability). With this ADR, KV admin grants are visible only in the bootstrap script's source code, not in TF plans. That's a fair tradeoff: the grants are immutable (set once, never change), so they don't need ongoing audit visibility. The bootstrap script is committed to git and is the source of truth for "who has access to the lab."

## Generalization

**Rule of thumb for this lab**: any role assignment that grants the TF runner itself permission to manage a resource should be **bootstrap-managed**, not TF-managed. Reason: if TF deletes or refactors its own access-grant role assignment mid-apply, recovery requires out-of-band intervention.

Role assignments that are TF-managed (safe):
- AKS kubelet → AcrPull on ACR (the principals don't run TF)
- mi-n8n-aoai → Cognitive Services OpenAI User on AOAI (Phase 1D)
- Workload SA federated credentials (Phase 1D)

Role assignments that should be bootstrap-managed (this ADR's pattern):
- GHA MI → Contributor on RG ✓
- GHA MI → User Access Administrator on RG ✓
- GHA MI → Storage Blob Data Contributor on state container ✓
- GHA MI → **Key Vault Administrator on RG** ✓ (added by this ADR)
- Human user → mirror of all the above ✓

## Migration / cleanup

For the existing 1B deployment:
- Manual `az role assignment create` already granted both MI and human KV Admin at RG scope (done as part of 1B.2 recovery, before this PR).
- After this PR merges, `terraform plan` should show: "0 to add, 0 to change, 0 to destroy" for KV role assignments — there's nothing in TF state to remove because the previous failed applies never successfully created the for_each entries.
- The unused `var.human_admin_object_id` and `HUMAN_ADMIN_OID` GitHub variable remain in place (harmless dead code) in case future modules need them. Can be removed in a future cleanup PR.
