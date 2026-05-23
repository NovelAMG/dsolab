# ADR 0010: Grant `Storage Blob Data Contributor` at the storage account scope (not container scope)

- **Status**: Accepted
- **Date**: 2026-05-23
- **Phase**: 1E-a (lessons captured from PR #4 plan failures)

## Context

The Terraform AzureRM backend stores state in an Azure Storage container. We
authenticate to that backend using the GitHub Actions managed identity (`mi-gha-dsolab`)
via OIDC, with `allow_shared_key_access = false` on the storage account — so all
data-plane calls are Entra ID-authenticated, no shared keys.

In our original bootstrap script we granted the MI (and the human admin) the
`Storage Blob Data Contributor` role at **container scope only**:

```text
${SA_ID}/blobServices/default/containers/tfstate
```

This is the most least-privilege scope and seemed correct.

It is not.

## Problem we hit

`terraform init` repeatedly failed with:

```text
Error: Failed to get existing workspaces: containers.Client#ListBlobs:
  ... Status=403 Code="AuthorizationFailure"
```

The AzureRM backend's workspace discovery calls `ListBlobs` against the account
(then filters per container/prefix). That data-plane operation is authorized at
**account scope** in Azure RBAC's evaluation — a role assignment scoped only to
a sub-container does not satisfy it for the parent listing call.

We worked around this manually three times during PR #4 by running:

```bash
az role assignment create \
  --assignee-object-id "$MI_OID" \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID"
```

## Decision

The bootstrap script (`scripts/00-bootstrap-state.sh`) grants
`Storage Blob Data Contributor` at **both** scopes for both the MI and the human admin:

- **Container scope** (`.../containers/tfstate`) — least privilege for the actual
  blob read/write operations.
- **Storage account scope** (`.../storageAccounts/<name>`) — required for the
  backend's `ListBlobs` discovery call.

Granting at SA scope alone would also work but is broader than needed for the
actual state operations; granting at both keeps intent explicit. The state
account holds only Terraform state, so SA-scope blob contributor on it is a
narrow blast radius regardless.

## Alternatives considered

1. **Use SAS tokens or shared keys for the backend.**
   Rejected. We deliberately set `allow_shared_key_access = false` to enforce
   Entra-only auth (Phase 1A goal). Switching would undo a Phase 1A decision.

2. **Use a SP with `Storage Account Contributor` (control-plane Owner-ish).**
   Rejected. Way too broad — that role grants key listing, account deletion, and
   network rule changes. The data-plane role is exactly what's needed.

3. **Keep container-scope and route through a private endpoint.**
   Rejected. Private endpoint doesn't change RBAC requirements. Different problem.

## Consequences

**Positive:**

- `terraform init` and `tf-plan` work on a fresh bootstrap with no manual fixes.
- ADR captures the surprise so future maintainers don't repeat the manual fix.
- Future contributors who bootstrap their own clone get a working pipeline first try.

**Negative:**

- The MI has Blob Data Contributor on the entire SA (which holds only `tfstate`).
  Risk is contained because the SA serves a single purpose.

## Verification

After running `00-bootstrap-state.sh`:

```bash
az role assignment list \
  --assignee "$(az identity show -g rg-dsolab-sea -n mi-gha-dsolab --query principalId -o tsv)" \
  --query "[?roleDefinitionName=='Storage Blob Data Contributor'].scope" -o tsv
```

Should print **two** lines: one container scope, one SA scope.

## Related

- ADR 0006 — AzureRM provider auto-registration disabled (same theme: backend
  init-time behaviour we have to plan around).
- ADR 0008 — KV admin via bootstrap (same pattern: granting auth at bootstrap
  scope instead of through Terraform, to break chicken-and-egg cycles).
