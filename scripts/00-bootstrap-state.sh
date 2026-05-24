#!/usr/bin/env bash
# Bootstrap one-time resources for the DevSecOps lab:
#   - Resource group
#   - Storage account + container for Terraform state
#   - User-assigned managed identity for GitHub Actions OIDC
#   - Federated credentials for main branch + PRs
#   - Role assignments (Contributor + UAA on RG, Blob Data Contributor on state container)
#   - GitHub repo variables (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, TF_STATE_*)
#
# Idempotent: safe to re-run. Tested on macOS + bash 3.2.

set -euo pipefail

# ---------- Config ----------
PREFIX="${PREFIX:-dsolab}"
LOCATION_PRIMARY="${LOCATION_PRIMARY:-southeastasia}"
GH_REPO="${GH_REPO:-NovelAMG/dsolab}"

RG_NAME="rg-${PREFIX}-sea"
MI_NAME="mi-gha-${PREFIX}"
STATE_CONTAINER="tfstate"
TF_STATE_KEY="lab.tfstate"

# Random suffix for storage account (must be globally unique, 3-24 lowercase alphanumeric)
SA_SUFFIX="${SA_SUFFIX:-$(openssl rand -hex 2)}"
SA_NAME="st${PREFIX}tfstate${SA_SUFFIX}"

# ---------- Pre-flight checks ----------
command -v az >/dev/null || { echo "ERROR: 'az' CLI not found. Install: brew install azure-cli"; exit 1; }
command -v gh >/dev/null || { echo "ERROR: 'gh' CLI not found. Install: brew install gh"; exit 1; }

az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az. Run 'az login'."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: not logged into gh. Run 'gh auth login'."; exit 1; }

# Verify the GitHub repo exists
gh repo view "$GH_REPO" >/dev/null 2>&1 || {
  echo "ERROR: repo $GH_REPO not found or not accessible. Create it first:"
  echo "  gh repo create $GH_REPO --private --confirm"
  exit 1
}

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SUB_NAME=$(az account show --query name -o tsv)

echo "=========================================="
echo "Bootstrapping DevSecOps lab"
echo "  Subscription: $SUB_NAME"
echo "  Sub ID:       $SUBSCRIPTION_ID"
echo "  Tenant:       $TENANT_ID"
echo "  Region:       $LOCATION_PRIMARY"
echo "  Resource grp: $RG_NAME"
echo "  GitHub repo:  $GH_REPO"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- 1. Resource group ----------
echo ""
echo "[1/6] Creating resource group $RG_NAME..."
az group create \
  --name "$RG_NAME" \
  --location "$LOCATION_PRIMARY" \
  --tags project=dsolab environment=lab managed_by=bootstrap \
  --output none

# ---------- 2. Storage account for TF state ----------
echo "[2/6] Creating storage account $SA_NAME..."

# Reuse existing if found (by prefix match)
EXISTING_SA=$(az storage account list \
  --resource-group "$RG_NAME" \
  --query "[?starts_with(name, 'st${PREFIX}tfstate')].name | [0]" \
  -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_SA" ]]; then
  echo "  Found existing SA: $EXISTING_SA — reusing"
  SA_NAME="$EXISTING_SA"
else
  az storage account create \
    --name "$SA_NAME" \
    --resource-group "$RG_NAME" \
    --location "$LOCATION_PRIMARY" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --tags project=dsolab environment=lab managed_by=bootstrap \
    --output none
fi

# Container creation requires the caller to have Blob Data Contributor first
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
SA_ID=$(az storage account show --name "$SA_NAME" --resource-group "$RG_NAME" --query id -o tsv)

echo "  Granting current user Blob Data Owner (so we can create the container)..."
az role assignment create \
  --assignee-object-id "$USER_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Owner" \
  --scope "$SA_ID" \
  --output none 2>/dev/null || echo "    (already assigned)"

echo "  Waiting 30s for RBAC to propagate..."
sleep 30

echo "  Creating container $STATE_CONTAINER..."
az storage container create \
  --account-name "$SA_NAME" \
  --name "$STATE_CONTAINER" \
  --auth-mode login \
  --output none 2>/dev/null || echo "    (container exists)"

# ---------- 3. User-assigned MI for GH OIDC ----------
echo "[3/6] Creating user-assigned managed identity $MI_NAME..."
az identity create \
  --name "$MI_NAME" \
  --resource-group "$RG_NAME" \
  --location "$LOCATION_PRIMARY" \
  --tags project=dsolab environment=lab managed_by=bootstrap \
  --output none

MI_CLIENT_ID=$(az identity show --name "$MI_NAME" --resource-group "$RG_NAME" --query clientId -o tsv)
MI_PRINCIPAL_ID=$(az identity show --name "$MI_NAME" --resource-group "$RG_NAME" --query principalId -o tsv)

# ---------- 4. Federated credentials ----------
echo "[4/6] Creating federated credentials for GitHub OIDC..."

create_fic() {
  local fc_name="$1"
  local fc_subject="$2"

  local exists
  exists=$(az identity federated-credential list \
    --identity-name "$MI_NAME" \
    --resource-group "$RG_NAME" \
    --query "[?name=='$fc_name'].name | [0]" -o tsv 2>/dev/null || true)

  if [[ -z "$exists" ]]; then
    az identity federated-credential create \
      --identity-name "$MI_NAME" \
      --resource-group "$RG_NAME" \
      --name "$fc_name" \
      --issuer "https://token.actions.githubusercontent.com" \
      --subject "$fc_subject" \
      --audiences "api://AzureADTokenExchange" \
      --output none
    echo "    Created FC: $fc_name → $fc_subject"
  else
    echo "    FC $fc_name exists, skipping"
  fi
}

create_fic "main-branch" "repo:${GH_REPO}:ref:refs/heads/main"
create_fic "pull-request" "repo:${GH_REPO}:pull_request"

# ---------- 5. Role assignments ----------
echo "[5/6] Assigning roles to MI..."
echo "  Waiting 15s for AAD propagation..."
sleep 15

assign_role() {
  local role="$1"
  local scope="$2"
  az role assignment create \
    --assignee-object-id "$MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$role" \
    --scope "$scope" \
    --output none 2>/dev/null \
    && echo "    Assigned: $role" \
    || echo "    Already assigned: $role"
}

RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}"
CONTAINER_SCOPE="${SA_ID}/blobServices/default/containers/${STATE_CONTAINER}"

assign_role "Contributor" "$RG_SCOPE"
assign_role "User Access Administrator" "$RG_SCOPE"
assign_role "Key Vault Administrator" "$RG_SCOPE"
# Storage Blob Data Contributor at BOTH scopes:
#   - container scope: needed for read/write of state blobs
#   - SA scope: required by the AzureRM backend's `ListBlobs` call during `terraform init`
# Granting at container scope alone causes recurring 403 ListBlobs failures in tf-plan.
# See ADR 0010.
assign_role "Storage Blob Data Contributor" "$CONTAINER_SCOPE"
assign_role "Storage Blob Data Contributor" "$SA_ID"

# Also grant the current user Key Vault Administrator on the RG (matches MI),
# and Blob Data Contributor on both SA scope + container scope (for local `terraform` runs).
# Without these, the human can't read KV secrets created by TF (ADR 0008) and
# `terraform init` fails locally (ADR 0010).
az role assignment create \
  --assignee-object-id "$USER_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Key Vault Administrator" \
  --scope "$RG_SCOPE" \
  --output none 2>/dev/null || true

az role assignment create \
  --assignee-object-id "$USER_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$CONTAINER_SCOPE" \
  --output none 2>/dev/null || true

az role assignment create \
  --assignee-object-id "$USER_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID" \
  --output none 2>/dev/null || true

# ---------- 6. Set GitHub repo variables ----------
echo "[6/6] Setting GitHub repo variables on $GH_REPO..."
gh variable set AZURE_CLIENT_ID       --body "$MI_CLIENT_ID"    --repo "$GH_REPO"
gh variable set AZURE_TENANT_ID       --body "$TENANT_ID"       --repo "$GH_REPO"
gh variable set AZURE_SUBSCRIPTION_ID --body "$SUBSCRIPTION_ID" --repo "$GH_REPO"
gh variable set TF_STATE_RG           --body "$RG_NAME"         --repo "$GH_REPO"
gh variable set TF_STATE_SA           --body "$SA_NAME"         --repo "$GH_REPO"
gh variable set TF_STATE_CONTAINER    --body "$STATE_CONTAINER" --repo "$GH_REPO"
gh variable set TF_STATE_KEY          --body "$TF_STATE_KEY"    --repo "$GH_REPO"

# Human admin OID — used by Terraform to grant the human user Key Vault
# Administrator alongside the GHA MI. Without this, only the MI would have KV access
# after `terraform apply` runs in CI.
gh variable set HUMAN_ADMIN_OID       --body "$USER_OBJECT_ID"  --repo "$GH_REPO"

# ---------- Done ----------
cat <<EOF

==========================================
✓ Bootstrap complete!
==========================================

Created resources:
  RG:       $RG_NAME
  SA:       $SA_NAME
  MI:       $MI_NAME
            (client id: $MI_CLIENT_ID)

GitHub repo variables set on $GH_REPO:
  AZURE_CLIENT_ID       = $MI_CLIENT_ID
  AZURE_TENANT_ID       = $TENANT_ID
  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID
  TF_STATE_RG           = $RG_NAME
  TF_STATE_SA           = $SA_NAME
  TF_STATE_CONTAINER    = $STATE_CONTAINER
  TF_STATE_KEY          = $TF_STATE_KEY
  HUMAN_ADMIN_OID       = $USER_OBJECT_ID  (you, as the human admin)

Local terraform init (for Phase 1B onward):

  terraform -chdir=terraform/envs/lab init \\
    -backend-config="resource_group_name=$RG_NAME" \\
    -backend-config="storage_account_name=$SA_NAME" \\
    -backend-config="container_name=$STATE_CONTAINER" \\
    -backend-config="key=$TF_STATE_KEY"

Next steps:
  1. git checkout -b infra/01-bootstrap
  2. git add . && git commit -m "chore: scaffold repo with bootstrap, providers, and hello-world workflow"
  3. git push -u origin infra/01-bootstrap
  4. gh pr create --fill --title "infra/01: bootstrap repo + OIDC smoke test"
  5. Watch the 'Hello World (OIDC smoke test)' workflow turn green on the PR.

EOF
