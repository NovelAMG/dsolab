# Runbook — Phase 1B: Core Azure infrastructure (Terraform modules)

**Goal**: stand up AKS + ACR + Key Vault + Log Analytics + Azure OpenAI (GPT-4o in `australiaeast`) + Postgres Flex via Terraform, with a proper PR review of the plan before apply.

**Time estimate**: ~5 min to open PR, ~5 min to review plan, ~20 min for `terraform apply` (AKS provisioning is the long pole).

## What this PR will create

| Resource | Module | Region | Why |
|---|---|---|---|
| Log Analytics workspace | `loganalytics` | SEA | Sink for AKS diagnostics + Container Insights |
| Azure Container Registry | `acr` | SEA | Holds SPA image (Phase 1E) |
| Key Vault | `keyvault` | SEA | Stores Postgres password + (later) n8n encryption key |
| AKS cluster | `aks` | SEA | Workload identity + OIDC issuer ON, Cilium CNI Overlay, Container Insights, 2× B2s nodes |
| Azure OpenAI (GPT-4o) | `openai` | **AUE** | Split region per ADR 0004; `local_auth_enabled = false` (no API keys) |
| Postgres Flex (B1ms) | `postgres` | SEA | n8n's DB; SQL auth + Entra hybrid; random password stored in KV |
| Postgres password in KV | composed in env | SEA | Pulled by n8n in Phase 1E |

**Expected monthly cost** (lab usage, single environment): ~$120–180/mo
- AKS nodes (2× B2s): ~$60
- Postgres B1ms: ~$15
- AOAI: pay-per-token (likely $5–20/mo at lab usage)
- ACR Standard: ~$20
- KV + LA + storage: ~$10

## Prerequisites

- [ ] Phase 1A merged on `main` (workflow `Hello World (OIDC smoke test)` is green)
- [ ] `gh variable list --repo NovelAMG/dsolab` shows 7 variables
- [ ] Your $200/mo budget alert is set in Azure Cost Management
- [ ] **One-time: register Azure Resource Providers** (your account, not CI):
  ```bash
  chmod +x scripts/01-register-resource-providers.sh
  ./scripts/01-register-resource-providers.sh
  ```
  This runs once per subscription. The GitHub Actions MI cannot register RPs itself (it's scoped to the RG, not the subscription), so we pre-register the 13 RPs we actually use. The script is idempotent.

## Step 1 — Pull main and create the feature branch

This is the **first real PR-driven change**. From now on, every change goes through this loop.

```bash
cd ~/Desktop/DevSecOps-True
git checkout main
git pull origin main
git checkout -b infra/02-core-resources
```

## Step 2 — Review what's about to be added

The new files are already in your working tree:

```bash
git status
# Expected: 23 new files (6 modules × 3 files, 2 env updates, 2 workflows, 1 runbook)
```

**Optional — local Terraform sanity check** (skip if you don't have `terraform` installed; CI does the same checks):

```bash
# Install once if missing
brew install terraform

terraform -chdir=terraform/envs/lab fmt -check -recursive ../.. && echo "✓ fmt clean"

terraform -chdir=terraform/envs/lab init \
  -backend-config="resource_group_name=$(gh variable get TF_STATE_RG --repo NovelAMG/dsolab)" \
  -backend-config="storage_account_name=$(gh variable get TF_STATE_SA --repo NovelAMG/dsolab)" \
  -backend-config="container_name=$(gh variable get TF_STATE_CONTAINER --repo NovelAMG/dsolab)" \
  -backend-config="key=$(gh variable get TF_STATE_KEY --repo NovelAMG/dsolab)"

terraform -chdir=terraform/envs/lab validate
```

**If you don't run this locally**: that's fine. The `Terraform Plan (PR)` workflow runs `fmt -check`, `init`, `validate`, and `plan` in CI and posts the plan to your PR as a comment. You'll see any errors there.

## Step 3 — Commit and push

```bash
git add .
git commit -m "infra(1b): add core modules (aks, acr, kv, la, aoai, postgres) and tf workflows"
git push -u origin infra/02-core-resources
```

## Step 4 — Open the PR

```bash
gh pr create --fill --title "infra/02: core infrastructure modules"
gh pr view --web
```

## Step 5 — Review the Terraform plan in the PR

Within ~2 minutes, the `Terraform Plan (PR)` workflow will:
1. Run `terraform fmt -check`, `init`, `validate`, `plan`
2. **Post the full plan as a PR comment** in a collapsible `<details>` block

**Critical**: open that comment and read the plan. You should see:
- ~30–40 resources to be **created**
- **0 to change, 0 to destroy**
- The AOAI account in `australiaeast` with `local_auth_enabled = false`
- AKS with `workload_identity_enabled = true` and `oidc_issuer_enabled = true`
- The Postgres password is shown as `(sensitive value)` — good

If anything looks off (wrong region, unexpected destroy, sensitive values exposed), close the PR and fix.

## Step 6 — Merge

```bash
gh pr merge --squash --delete-branch
```

The `Terraform Apply (main)` workflow will trigger automatically. **AKS takes ~15 minutes** — the most patient phase.

Watch it:
```bash
gh run watch $(gh run list --workflow=tf-apply.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

## Step 7 — Verify the cluster works

After the apply completes:

```bash
# Get cluster credentials
az aks get-credentials \
  --resource-group rg-dsolab-sea \
  --name aks-dsolab-sea \
  --overwrite-existing

# Sanity-check
kubectl get nodes
# Expected: 2 nodes, status Ready, Kubernetes version 1.30+

kubectl get ns
# Expected: default, kube-system, kube-node-lease, kube-public (no gatekeeper-system!)

kubectl get ds -A | grep -i defender
# Expected: no rows — Defender sensor is OFF per Phase 1C ADR.

# AOAI: GPT-4o deployed + API keys correctly disabled
az cognitiveservices account deployment list \
  --resource-group rg-dsolab-sea \
  --name aoai-dsolab-aue \
  --query "[].{name:name, model:properties.model.name, version:properties.model.version, sku:sku.name}" -o table
# Expected: one row showing gpt-4o, version 2024-11-20, sku GlobalStandard

az cognitiveservices account keys list \
  --resource-group rg-dsolab-sea \
  --name aoai-dsolab-aue 2>&1 | head -3
# Expected: error "Failed to list key. disableLocalAuth is set to be true" — that IS the desired state.

# Key Vault should have 3 secrets
KV_NAME=$(az keyvault list --resource-group rg-dsolab-sea --query "[0].name" -o tsv)
az keyvault secret list --vault-name "$KV_NAME" --query "[].name" -o tsv
# Expected: postgres-admin-login, postgres-admin-password, postgres-fqdn
```

## Step 8 — Set yourself as Postgres Entra admin (one-time, manual)

The Postgres server is up but the Entra admin isn't wired (Terraform can't easily know your UPN). Set it once:

```bash
PSQL_NAME=$(az postgres flexible-server list --resource-group rg-dsolab-sea --query "[0].name" -o tsv)
USER_UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv)
USER_OID=$(az ad signed-in-user show --query id -o tsv)

az postgres flexible-server microsoft-entra-admin create \
  --resource-group rg-dsolab-sea \
  --server-name "$PSQL_NAME" \
  --display-name "$USER_UPN" \
  --object-id "$USER_OID" \
  --type User
```

> **Note**: the subcommand is `microsoft-entra-admin` (azure-cli ≥ 2.70). Older docs used `ad-admin` which was deprecated.

## Phase 1B exit criteria

```bash
# 1. tf-apply workflow ran green on main
gh run list --workflow=tf-apply.yml --limit 1
#    Expected: completed success

# 2. All resources exist
az resource list --resource-group rg-dsolab-sea --query "length(@)" -o tsv
#    Expected: ~12+ (count varies as Azure auto-creates supporting resources)

# 3. AKS is healthy
kubectl get nodes
#    Expected: 2 nodes Ready

# 4. AOAI has GPT-4o deployed and refuses API keys
az cognitiveservices account deployment list \
  --resource-group rg-dsolab-sea \
  --name $(terraform -chdir=terraform/envs/lab output -raw aoai_endpoint | awk -F. '{print $1}' | awk -F/ '{print $NF}') \
  --query "[].name" -o tsv
#    Expected: "gpt-4o"

# 5. KV holds the Postgres password
az keyvault secret list --vault-name $(terraform -chdir=terraform/envs/lab output -raw key_vault_name) --query "[].name" -o tsv
#    Expected: postgres-admin-login, postgres-admin-password, postgres-fqdn

# 6. No Defender sensor pods running
kubectl get pods -A | grep -i defender || echo "✓ no defender pods (correct for Phase 1B)"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `terraform init` fails 403 on state container | Local user lacks Blob Data Contributor | Re-run `scripts/00-bootstrap-state.sh` — it re-grants the role idempotently |
| `tf-plan` workflow comment is empty | Plan output >65k chars truncated incorrectly | Open the workflow run's `terraform plan` step log to see the full plan |
| AOAI quota error in apply: "InsufficientQuota" | GPT-4o `GlobalStandard` capacity in AUE | Azure portal → Quotas → Cognitive Services → request increase to 30+ TPM; then re-run apply |
| AKS apply fails: "SubnetIsFull" / "InsufficientCpuQuota" | Subscription vCPU quota in SEA | Azure portal → Quotas → Compute → request more vCPUs in `southeastasia` |
| Postgres apply fails: "ResourceQuotaExceeded" | Burstable family quota | Quotas → Postgres Flexible Servers → request increase |
| `kubectl get nodes` after apply: "No connection" | `az aks get-credentials` not run yet | Run the command in Step 7 |
| `az postgres ad-admin create` fails: `'ad-admin' is misspelled` | azure-cli ≥ 2.70 renamed the subcommand | Use `az postgres flexible-server microsoft-entra-admin create ...` (see Step 8) |
| KV access denied (`ForbiddenByRbac`) on `az keyvault secret list` after a CI-run apply | The `data.azurerm_client_config.current.object_id` in CI resolves to the GHA MI, not you. Without the `HUMAN_ADMIN_OID` GitHub variable set, only the MI got KV Administrator. | Set the variable: `gh variable set HUMAN_ADMIN_OID --body $(az ad signed-in-user show --query id -o tsv) --repo NovelAMG/dsolab`, then re-run `terraform apply` (or grant yourself manually: `az role assignment create --assignee-object-id $(az ad signed-in-user show --query id -o tsv) --role 'Key Vault Administrator' --scope $(az keyvault show -n <kv-name> --query id -o tsv)`) |

## What's next

After Phase 1B merges and you've verified the exit criteria: **Phase 1C** — toggle Defender Containers sensor OFF (the docs-only ADR PR). This is a 5-minute step and prepares the cluster for the deliberate Phase 3 enablement.
