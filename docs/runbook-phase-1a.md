# Runbook — Phase 1A: Repo bootstrap + GitHub OIDC

**Goal**: prove you can authenticate from GitHub Actions to Azure using OIDC, with **zero secrets stored in GitHub**.

**Time estimate**: ~15 minutes (most of it waiting for Azure RBAC propagation).

## Prerequisites checklist

- [ ] `az --version` returns 2.60 or higher
- [ ] `az account show` works (you are logged in to the **right subscription**)
- [ ] `gh --version` works; `gh auth status` shows you're logged into `github.com`
- [ ] You have **Owner** on the subscription (or Contributor **+** User Access Administrator)
- [ ] The empty repo `NovelAMG/dsolab` exists on GitHub
- [ ] Your local `~/Desktop/DevSecOps-True` is git-initialized and `origin` points at the GitHub repo

If `origin` is not set yet:
```bash
cd ~/Desktop/DevSecOps-True
git init
git branch -M main
git remote add origin https://github.com/NovelAMG/dsolab.git
```

## Step 1 — Run the bootstrap script

```bash
chmod +x scripts/00-bootstrap-state.sh
./scripts/00-bootstrap-state.sh
```

The script will:
1. Show what it's about to create. Press `y` to confirm.
2. Create resource group `rg-dsolab-sea` in `southeastasia`.
3. Create storage account `stdsolabtfstate<random>` for Terraform state (Entra auth only, no shared keys).
4. Create user-assigned managed identity `mi-gha-dsolab` for GitHub Actions OIDC.
5. Create 2 federated credentials on the MI (one for `main` pushes, one for PRs).
6. Assign roles: Contributor + User Access Administrator on the RG, Storage Blob Data Contributor on the state container.
7. Set 7 repo variables on `NovelAMG/dsolab` via `gh variable set`.
8. Print the storage account name and a one-liner for `terraform init`.

**Watch for**: at the end, you should see `✓ Bootstrap complete!` with all 7 GitHub variables listed.

> **Common gotcha**: the script sleeps ~45 seconds total to wait for Azure RBAC to propagate. Don't Ctrl-C — the sleep is necessary.

## Step 2 — Verify the bootstrap

### In Azure portal
- Resource groups → `rg-dsolab-sea` → should show **2 resources**: the storage account and the managed identity.
- Open the managed identity → **Federated credentials** blade → should show **2 entries** with subjects:
  - `repo:NovelAMG/dsolab:ref:refs/heads/main`
  - `repo:NovelAMG/dsolab:pull_request`

### In GitHub repo settings
- Settings → Secrets and variables → Actions → **Variables** tab → should show **7 variables**.
- ⚠️ Confirm they're under **Variables**, NOT **Secrets**. There should be **zero secrets**.

### On terminal
```bash
gh variable list --repo NovelAMG/dsolab
gh secret list --repo NovelAMG/dsolab   # should print nothing
```

## Step 3 — Commit and push the scaffold

> ⚠️ **First-commit caveat**: an empty GitHub repo has no `main` branch yet. If you push a feature branch first, GitHub auto-sets it as the default branch and you can't open a PR (base == head). For the **initial scaffold only**, push directly to `main`. From Phase 1B onward, all changes go through feature-branch → PR → merge.

```bash
git checkout -b main
git add .
git status   # review what's about to be committed — should NOT include any state files or .env

git commit -m "chore: scaffold repo with bootstrap, providers, and hello-world workflow"
git push -u origin main
```

> **Common gotcha**: if `git status` shows `terraform/envs/lab/terraform.tfstate` or similar, your `.gitignore` is not working — verify it's in the repo root and contains the Terraform rules.

## Step 4 — Trigger the OIDC smoke test on `main`

Since we pushed direct to `main`, there's no PR. Trigger the workflow manually:

```bash
gh workflow run hello-world.yml --ref main
sleep 5
gh run watch $(gh run list --workflow=hello-world.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Expected output: workflow completes with `success`. From Phase 1B onward, this workflow will also auto-run on every PR that touches it.

## Step 5 — Recover if you accidentally pushed to a feature branch first

If you ran `git checkout -b infra/01-bootstrap` + `git push -u origin infra/01-bootstrap` before reading this, you'll get exit code 1 from `gh pr create` with no useful error. Fix:

```bash
# Rename your feature branch to main locally + push as main + set default + clean up
git branch -m infra/01-bootstrap main
git push -u origin main
gh repo edit NovelAMG/dsolab --default-branch main
git push origin --delete infra/01-bootstrap
gh workflow run hello-world.yml --ref main
```


## Phase 1A exit criteria

```bash
# 1. Workflow ran green on main
gh run list --workflow="hello-world.yml" --limit 1
#    Expected: 1 row, "completed success"

# 2. No secrets in the repo
gh secret list --repo NovelAMG/dsolab
#    Expected: empty (only variables are set, which is fine)

# 3. main is the default branch and has the scaffold
git checkout main && git pull
git log --oneline -3
#    Expected: top commit is your scaffold

# 4. Local terraform init works
terraform -chdir=terraform/envs/lab init \
  -backend-config="resource_group_name=$(gh variable get TF_STATE_RG --repo NovelAMG/dsolab)" \
  -backend-config="storage_account_name=$(gh variable get TF_STATE_SA --repo NovelAMG/dsolab)" \
  -backend-config="container_name=$(gh variable get TF_STATE_CONTAINER --repo NovelAMG/dsolab)" \
  -backend-config="key=$(gh variable get TF_STATE_KEY --repo NovelAMG/dsolab)"
#    Expected: "Terraform has been successfully initialized!"

# 5. terraform plan against the (empty) lab shows no changes
terraform -chdir=terraform/envs/lab plan
#    Expected: "No changes. Your infrastructure matches the configuration."
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `az: command not found` | Azure CLI not installed | `brew install azure-cli` |
| `gh: command not found` | GitHub CLI not installed | `brew install gh` |
| `Failed to validate identity provider` in workflow | FIC subject mismatch | Verify FIC subject in Azure portal matches `repo:NovelAMG/dsolab:ref:refs/heads/main` exactly (no trailing whitespace, exact case) |
| `403 AuthorizationFailed` in workflow | RBAC not propagated yet | Wait 5 min, then re-run via Actions tab → Re-run workflow |
| `Storage account name already taken` | Random suffix collision (extremely rare) | Re-run the script — it generates a new 4-hex suffix |
| `terraform init` says "Failed to get existing workspaces" with 403 | You don't have Blob Data Contributor on the container | The bootstrap script grants it to your user; re-run the script, or assign manually via portal |
| Bootstrap script exits with "repo not found" | Repo not created on GitHub yet | `gh repo create NovelAMG/dsolab --private --confirm` |
| Bootstrap script exits with "Insufficient privileges" on role assignment | You don't have Owner / UAA on the subscription | Escalate via PIM, or ask sub owner to run the script |
| `gh pr create --fill` exits code 1 silently | First push went to a feature branch on an empty repo — `main` doesn't exist, default branch is your feature branch, base == head | See Step 5 above: rename feature branch to `main`, push, set default, delete old branch |

## What's next

After this PR is merged: **Phase 1B** — Core Azure infrastructure (AKS, ACR, AOAI, Postgres, KV) via Terraform modules. The `tf-plan.yml` and `tf-apply.yml` workflows will be added in 1B, hooked to the OIDC plumbing you just verified works.
