# Runbook — Phase 1C + 1D: Defender posture ADR + identity setup

**Goal**:
- **1C** (docs only): commit ADR 0001 capturing the Defender posture decision you already implemented in Azure.
- **1D** (real work): create n8n's workload identity (`mi-n8n-aoai-dsolab`) + the two Entra app registrations (`spa-dsolab`, `n8n-api-dsolab`) the SPA/oauth2-proxy will use in Phase 1E.

**Time estimate**: ~15 min total (1C is docs only; 1D = run one script + open one PR).

## Prerequisites

- [ ] Phase 1B fully done (tf-apply green, AKS Running, KV accessible)
- [ ] You have **Application Administrator** role available (PIM activate if needed) — needed for Entra app reg creation
- [ ] `az`, `gh`, `jq`, `uuidgen` installed locally (jq is the only one you might be missing — `brew install jq`)

## Step 1 — Run the Entra app reg bootstrap script

```bash
cd ~/Desktop/DevSecOps-True
chmod +x scripts/02-create-entra-apps.sh
./scripts/02-create-entra-apps.sh
```

The script will:
1. Confirm with you before creating anything.
2. Create `n8n-api-dsolab` app reg, then PATCH its identifier URI to `api://{appId}` (the only format your tenant's `identifierUriAddingDisabled` policy permits) + `requestedAccessTokenVersion=2` + custom scope `access_as_user`.
3. Create `spa-dsolab` app reg as a SPA-type with redirect URI `http://localhost:5173/auth/callback`. Add delegated permissions to `n8n-api-dsolab/access_as_user` + Microsoft Graph `User.Read`.
4. Pre-authorize the SPA on n8n-api (so users skip the consent prompt).
5. Grant tenant-wide admin consent for the SPA's permissions.
6. Set 3 GitHub repo variables: `N8N_API_APP_ID`, `N8N_API_APP_URI`, `SPA_APP_ID`.

**Idempotent**: re-running detects existing apps by display name and reuses them.

## Step 2 — Verify the bootstrap

### In Entra admin center
- App registrations → `n8n-api-dsolab` → Expose an API → should show one scope `access_as_user`, status Enabled.
- App registrations → `spa-dsolab` → Authentication → Single-page application → should list `http://localhost:5173/auth/callback`.
- App registrations → `spa-dsolab` → API permissions → should show:
  - `n8n-api-dsolab/access_as_user` — Delegated — **Granted for tenant** ✓
  - `Microsoft Graph/User.Read` — Delegated — **Granted for tenant** ✓

### On terminal
```bash
gh variable list --repo tonzking123/dsolab
# Should include N8N_API_APP_ID, N8N_API_APP_URI, SPA_APP_ID (alongside the existing AZURE_* and TF_STATE_*)
```

## Step 3 — Commit + push the Phase 1C/1D Terraform changes

Files already in your working tree (added in this PR):

- `docs/decisions/0001-defer-defender-sensor-to-phase-3.md` *(1C ADR)*
- `docs/decisions/0009-bootstrap-manages-entra-app-regs.md` *(1D ADR)*
- `scripts/02-create-entra-apps.sh` *(you just ran it)*
- `terraform/modules/identity/{main,variables,outputs}.tf` *(new module)*
- `terraform/envs/lab/{main,variables,outputs}.tf` *(updates to wire in the new module + new variables)*
- `.github/workflows/{tf-plan,tf-apply}.yml` *(pass new TF_VAR_* env vars)*
- This runbook

```bash
git checkout main && git pull
git checkout -b feat/03-identity-and-apps
git add .
git status
git commit -m "feat(1cd): adr 0001 + identity module + entra-apps bootstrap (adr 0009)"
git push -u origin feat/03-identity-and-apps
gh pr create --fill --title "feat/03: Phase 1C+1D — identity + ADRs"
gh pr view --web
```

## Step 4 — Review the tf-plan comment

In the PR's bot-posted Terraform Plan comment, you should see:

```
Plan: 3 to add, 0 to change, 0 to destroy.
```

The 3 adds are:
1. `module.identity.azurerm_user_assigned_identity.n8n_aoai` — the workload MI
2. `module.identity.azurerm_federated_identity_credential.k8s_sa` — FIC binding to (future) K8s SA `n8n:n8n`
3. `module.identity.azurerm_role_assignment.aoai_user` — `Cognitive Services OpenAI User` on the AOAI account

If the plan matches → merge.

## Step 5 — Merge + watch apply

```bash
gh pr merge --squash --delete-branch
gh run watch $(gh run list --workflow=tf-apply.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Should complete in <60 seconds — these are tiny resources.

## Step 6 — Verify the workload identity

```bash
# MI exists
az identity show -g rg-dsolab-sea -n mi-n8n-aoai-dsolab --query "{name:name, clientId:clientId, principalId:principalId}" -o table

# FIC exists with correct subject
az identity federated-credential list \
  --identity-name mi-n8n-aoai-dsolab \
  --resource-group rg-dsolab-sea \
  --query "[].{name:name, subject:subject, issuer:issuer}" -o table
# Expected subject: system:serviceaccount:n8n:n8n
# Expected issuer:  https://<region>.oic.prod-aks.azure.com/<tenant>/<cluster>/

# Role assignment on AOAI
AOAI_ID=$(az cognitiveservices account show -g rg-dsolab-sea -n aoai-dsolab-aue --query id -o tsv)
az role assignment list --scope "$AOAI_ID" --query "[?roleDefinitionName=='Cognitive Services OpenAI User'].{principal:principalName, type:principalType}" -o table
# Expected: mi-n8n-aoai-dsolab as ServicePrincipal
```

## Phase 1C+1D exit criteria

```bash
# 1. ADRs merged
ls docs/decisions/ | grep -E "(0001|0009)"
# Expected: both files

# 2. Entra apps exist
az ad app list --display-name "n8n-api-dsolab" --query "[].appId" -o tsv
az ad app list --display-name "spa-dsolab"     --query "[].appId" -o tsv
# Expected: one appId each

# 3. GitHub variables set
gh variable list --repo tonzking123/dsolab | grep -E "(SPA_APP_ID|N8N_API_APP_ID|N8N_API_APP_URI)"
# Expected: 3 rows

# 4. Terraform created the identity
terraform_outputs_via_az() {
  echo "MI client ID: $(az identity show -g rg-dsolab-sea -n mi-n8n-aoai-dsolab --query clientId -o tsv)"
}
terraform_outputs_via_az
# Expected: a GUID, not empty

# 5. AKS still healthy
kubectl get nodes
# Expected: 2 nodes Ready
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Bootstrap script fails: "Authorization_RequestDenied" on `az ad app create` | Your role isn't Application Administrator | Activate via PIM, then re-run script |
| Bootstrap script fails: "All newly added URIs must contain a tenant verified domain, tenant ID, or app ID" | Tenant policy `identifierUriAddingDisabled` blocks arbitrary `api://...` URIs | The script handles this by using `api://{appId}` (always allowed). If you still see this, you may be on an old script version — ensure scripts/02-create-entra-apps.sh creates the app first then PATCHes the URI. |
| `az ad app permission admin-consent` fails: "Insufficient privileges" | Need Cloud Application Administrator (or higher) for tenant-wide consent | Either escalate (PIM Cloud App Admin) OR grant consent manually in Entra admin center → SPA app → API permissions → "Grant admin consent for [tenant]" |
| tf-plan fails: "Reference to undeclared input variable `n8n_api_app_uri`" | Workflow YAMLs didn't pick up the new env var | Verify `.github/workflows/tf-plan.yml` has `TF_VAR_n8n_api_app_uri: ${{ vars.N8N_API_APP_URI }}` in the env block. Push the fix. |
| tf-apply fails: "PrincipalNotFound" on AOAI role assignment | MI created seconds ago; AAD propagation delay | The role assignment usually retries successfully. Re-run the workflow once. |
| Bootstrap script error: "jq: command not found" | jq isn't installed | `brew install jq` and re-run |

## What's next

**Phase 1E**: deploy n8n + oauth2-proxy + SPA on AKS using Kustomize manifests + an ingress with `nip.io`. The K8s ServiceAccount `n8n:n8n` you've already wired the FIC for gets created. The SPA reads its `client_id` from `terraform output spa_app_id`. oauth2-proxy reads its expected audience from `terraform output n8n_api_application_id_uri`.

That's the moment Phase 1's mental model turns into a working web app you can sign in to.
