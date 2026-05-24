#!/usr/bin/env bash
# Phase 1D bootstrap — create the two Entra app registrations the lab needs:
#   - n8n-api-dsolab : custom API with scope `access_as_user` (audience for oauth2-proxy)
#   - spa-dsolab     : SPA (PKCE) with delegated permission to n8n-api + Microsoft Graph User.Read
#
# Why this is a script (not Terraform): see docs/decisions/0009-bootstrap-manages-entra-app-regs.md
#
# Idempotent: re-running detects existing apps by display name and reuses them.
# Required role: Application Administrator (or Global Administrator).

set -euo pipefail

# ---------- Config ----------
PREFIX="${PREFIX:-dsolab}"
GH_REPO="${GH_REPO:-NovelAMG/dsolab}"

N8N_API_DISPLAY="n8n-api-${PREFIX}"
SPA_DISPLAY="spa-${PREFIX}"
SPA_REDIRECT_URI_LOCAL="http://localhost:5173/auth/callback"
# N8N_API_URI is set dynamically after the app is created to `api://{appId}`
# (the only identifier-URI format that always works regardless of tenant policy
# `identifierUriAddingDisabled`, which blocks arbitrary URIs like `api://n8n-dsolab`).

# Microsoft Graph well-known IDs
MS_GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
MS_GRAPH_USER_READ_SCOPE_ID="e1fe6dd8-ba31-4d61-89e7-88639da4683d"

# ---------- Pre-flight ----------
command -v az >/dev/null || { echo "ERROR: 'az' CLI not found"; exit 1; }
command -v gh >/dev/null || { echo "ERROR: 'gh' CLI not found"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: 'jq' not found. brew install jq"; exit 1; }
command -v uuidgen >/dev/null || { echo "ERROR: 'uuidgen' not found"; exit 1; }

az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az. Run 'az login'."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: not logged into gh. Run 'gh auth login'."; exit 1; }

TENANT_ID=$(az account show --query tenantId -o tsv)

echo "=========================================="
echo "Creating Entra app registrations"
echo "  Tenant:        $TENANT_ID"
echo "  n8n-api app:   $N8N_API_DISPLAY  (URI will be api://<appId>)"
echo "  SPA app:       $SPA_DISPLAY"
echo "  GitHub repo:   $GH_REPO"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- 1. n8n-api app reg ----------
echo ""
echo "[1/5] Creating/finding n8n-api app registration..."

N8N_API_APP_ID=$(az ad app list --display-name "$N8N_API_DISPLAY" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$N8N_API_APP_ID" ]]; then
  echo "  Found existing app: $N8N_API_APP_ID — reusing"
  # Look up existing scope ID (so we don't generate a new one and orphan the old)
  API_SCOPE_ID=$(az ad app show --id "$N8N_API_APP_ID" --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" -o tsv)
  if [[ -z "$API_SCOPE_ID" || "$API_SCOPE_ID" == "null" ]]; then
    echo "  WARN: existing app has no 'access_as_user' scope — will add via PATCH below"
    API_SCOPE_ID=$(uuidgen | tr 'A-Z' 'a-z')
  fi
else
  # Create WITHOUT --identifier-uris (the tenant policy blocks arbitrary URIs).
  # We add `api://{appId}` via Graph PATCH below — that format is always allowed.
  N8N_API_APP_ID=$(az ad app create \
    --display-name "$N8N_API_DISPLAY" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  echo "  Created app: $N8N_API_APP_ID"
  API_SCOPE_ID=$(uuidgen | tr 'A-Z' 'a-z')
fi

# Set the URI to `api://{appId}` — the format every tenant policy allows.
N8N_API_URI="api://${N8N_API_APP_ID}"
echo "  Configuring identifierUris=$N8N_API_URI, requestedAccessTokenVersion=2, and scope access_as_user..."

TMP_API_JSON=$(mktemp)
cat > "$TMP_API_JSON" <<EOF
{
  "identifierUris": ["$N8N_API_URI"],
  "api": {
    "requestedAccessTokenVersion": 2,
    "oauth2PermissionScopes": [{
      "id": "$API_SCOPE_ID",
      "adminConsentDescription": "Allow the application to call n8n APIs on behalf of the signed-in user",
      "adminConsentDisplayName": "Access n8n as user",
      "userConsentDescription": "Allow the application to call n8n APIs on your behalf",
      "userConsentDisplayName": "Access n8n as you",
      "value": "access_as_user",
      "type": "User",
      "isEnabled": true
    }]
  }
}
EOF

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications(appId='$N8N_API_APP_ID')" \
  --headers "Content-Type=application/json" \
  --body @"$TMP_API_JSON"
rm -f "$TMP_API_JSON"
echo "  Scope + URI configured."

# Ensure SP for the n8n-api app exists
echo "  Ensuring service principal for n8n-api..."
az ad sp show --id "$N8N_API_APP_ID" >/dev/null 2>&1 || \
  az ad sp create --id "$N8N_API_APP_ID" --query id -o tsv >/dev/null

# ---------- 2. SPA app reg ----------
echo ""
echo "[2/5] Creating/finding SPA app registration..."

SPA_APP_ID=$(az ad app list --display-name "$SPA_DISPLAY" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -n "$SPA_APP_ID" ]]; then
  echo "  Found existing app: $SPA_APP_ID — reusing"
else
  SPA_APP_ID=$(az ad app create \
    --display-name "$SPA_DISPLAY" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  echo "  Created SPA app: $SPA_APP_ID"
fi

# Configure SPA-type redirect URI + required permissions in one PATCH
echo "  Configuring SPA redirect URI + required permissions..."
TMP_SPA_JSON=$(mktemp)
cat > "$TMP_SPA_JSON" <<EOF
{
  "spa": {
    "redirectUris": ["$SPA_REDIRECT_URI_LOCAL"]
  },
  "requiredResourceAccess": [
    {
      "resourceAppId": "$N8N_API_APP_ID",
      "resourceAccess": [
        { "id": "$API_SCOPE_ID", "type": "Scope" }
      ]
    },
    {
      "resourceAppId": "$MS_GRAPH_APP_ID",
      "resourceAccess": [
        { "id": "$MS_GRAPH_USER_READ_SCOPE_ID", "type": "Scope" }
      ]
    }
  ]
}
EOF
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications(appId='$SPA_APP_ID')" \
  --headers "Content-Type=application/json" \
  --body @"$TMP_SPA_JSON"
rm -f "$TMP_SPA_JSON"

# Ensure SP for SPA exists
echo "  Ensuring service principal for SPA..."
az ad sp show --id "$SPA_APP_ID" >/dev/null 2>&1 || \
  az ad sp create --id "$SPA_APP_ID" --query id -o tsv >/dev/null

# ---------- 3. Pre-authorize SPA on n8n-api ----------
echo ""
echo "[3/5] Pre-authorizing SPA on n8n-api (skips end-user consent prompt)..."

# Get the current preAuthorizedApplications list, add SPA if not present
PRE_AUTH=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/applications(appId='$N8N_API_APP_ID')" \
  --query "api.preAuthorizedApplications" -o json 2>/dev/null || echo "[]")

if echo "$PRE_AUTH" | jq -e --arg id "$SPA_APP_ID" '.[] | select(.appId == $id)' >/dev/null 2>&1; then
  echo "  SPA already pre-authorized — skipping"
else
  NEW_PRE_AUTH=$(echo "$PRE_AUTH" | jq --arg id "$SPA_APP_ID" --arg scope "$API_SCOPE_ID" \
    '. + [{appId: $id, delegatedPermissionIds: [$scope]}]')
  TMP_PA_JSON=$(mktemp)
  echo "{\"api\": {\"preAuthorizedApplications\": $NEW_PRE_AUTH}}" > "$TMP_PA_JSON"
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications(appId='$N8N_API_APP_ID')" \
    --headers "Content-Type=application/json" \
    --body @"$TMP_PA_JSON"
  rm -f "$TMP_PA_JSON"
  echo "  Pre-authorized SPA $SPA_APP_ID for scope access_as_user."
fi

# ---------- 4. Tenant-wide admin consent (via Graph oAuth2PermissionGrants) ----------
echo ""
echo "[4/5] Granting tenant-wide admin consent for SPA's permissions..."
echo "  (Uses Microsoft Graph directly — avoids the legacy 'az ad app permission admin-consent'"
echo "  command's known issue where it conflicts with just-created service principals.)"

# Wait for SP propagation
sleep 5

SPA_SP_OID=$(az ad sp show --id "$SPA_APP_ID" --query id -o tsv)
API_SP_OID=$(az ad sp show --id "$N8N_API_APP_ID" --query id -o tsv)
MSGRAPH_SP_OID=$(az ad sp show --id "$MS_GRAPH_APP_ID" --query id -o tsv)

grant_consent() {
  local client_sp_oid="$1"
  local resource_sp_oid="$2"
  local scope="$3"
  local label="$4"

  local existing
  existing=$(az rest --method GET \
    --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId eq '$client_sp_oid' and resourceId eq '$resource_sp_oid'" \
    --query "value[?contains(scope, '$scope')] | [0].id" -o tsv 2>/dev/null || true)

  if [[ -n "$existing" && "$existing" != "null" ]]; then
    echo "  ✓ $label — consent already granted"
    return
  fi

  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
    --headers "Content-Type=application/json" \
    --body "{
      \"clientId\": \"$client_sp_oid\",
      \"consentType\": \"AllPrincipals\",
      \"resourceId\": \"$resource_sp_oid\",
      \"scope\": \"$scope\"
    }" --output none
  echo "  ✓ $label — consent granted"
}

grant_consent "$SPA_SP_OID" "$API_SP_OID"     "access_as_user" "SPA → n8n-api/access_as_user"
grant_consent "$SPA_SP_OID" "$MSGRAPH_SP_OID" "User.Read"      "SPA → Microsoft Graph/User.Read"

# ---------- 5. Set GitHub repo variables ----------
echo ""
echo "[5/5] Setting GitHub repo variables on $GH_REPO..."
gh variable set N8N_API_APP_ID  --body "$N8N_API_APP_ID"  --repo "$GH_REPO"
gh variable set N8N_API_APP_URI --body "$N8N_API_URI"     --repo "$GH_REPO"
gh variable set SPA_APP_ID      --body "$SPA_APP_ID"      --repo "$GH_REPO"

# ---------- Done ----------
cat <<EOF

==========================================
✓ Entra app registrations ready!
==========================================

App registrations created/reused:
  $N8N_API_DISPLAY
    appId:     $N8N_API_APP_ID
    URI:       $N8N_API_URI
    scope:     access_as_user (id: $API_SCOPE_ID)

  $SPA_DISPLAY
    appId:     $SPA_APP_ID
    redirect:  $SPA_REDIRECT_URI_LOCAL

GitHub repo variables set on $GH_REPO:
  N8N_API_APP_ID  = $N8N_API_APP_ID
  N8N_API_APP_URI = $N8N_API_URI
  SPA_APP_ID      = $SPA_APP_ID

Next steps:
  1. Commit any pending Phase 1D Terraform changes.
  2. git checkout -b feat/03-identity-and-apps
  3. git add . && git commit -m "feat(1cd): identity module + ADRs 0001/0009 + entra-apps bootstrap"
  4. git push -u origin feat/03-identity-and-apps
  5. gh pr create --fill --title "feat/03: Phase 1C+1D — identity + ADRs"
  6. Review the tf-plan comment (should show n8n workload MI + FIC + AOAI role assignment).
  7. Merge → tf-apply runs → MI is created.

Phase 1E will use the SPA app ID for MSAL config and the n8n-api URI for oauth2-proxy.

EOF
