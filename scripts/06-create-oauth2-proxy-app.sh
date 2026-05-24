#!/usr/bin/env bash
# Phase 1E-c — create Entra app registration for oauth2-proxy.
#
# Why a NEW app reg (vs. reusing n8n-api or spa)?
#   - oauth2-proxy is a CONFIDENTIAL CLIENT acting on behalf of users.
#     It holds a client secret and runs server-side. Entra "Web" platform.
#   - The SPA app reg (spa-dsolab) is a PUBLIC client (PKCE, no secret).
#     Wrong platform type.
#   - The n8n-api app reg is a RESOURCE SERVER (audience for tokens).
#     Wrong role.
#
# What this creates:
#   - App reg `oauth2-proxy-dsolab` with Web platform
#   - Redirect URI: https://<INGRESS_HOST>/oauth2/callback
#   - Client secret (24-month expiry) — stored in Key Vault as
#     `oauth2-proxy-client-secret`
#   - App ID stored in KV as `oauth2-proxy-client-id` and as GitHub variable
#     OAUTH2_PROXY_APP_ID
#
# Idempotent: re-running rotates the secret if needed; redirect URI is
# added only if missing.

set -euo pipefail

# ---------- Config ----------
PREFIX="${PREFIX:-dsolab}"
RG_NAME="${RG_NAME:-rg-${PREFIX}-sea}"
GH_REPO="${GH_REPO:-NovelAMG/dsolab}"
APP_NAME="oauth2-proxy-${PREFIX}"
KV_NAME="${KV_NAME:-}"

# Auto-derive INGRESS_HOST from the current LB IP if not provided.
INGRESS_HOST="${INGRESS_HOST:-}"

# ---------- Pre-flight ----------
command -v az      >/dev/null || { echo "ERROR: az not found."; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found."; exit 1; }
command -v gh      >/dev/null || { echo "ERROR: gh not found."; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az."; exit 1; }

if [[ -z "$KV_NAME" ]]; then
  KV_NAME=$(az keyvault list -g "$RG_NAME" --query "[0].name" -o tsv)
  [[ -n "$KV_NAME" ]] || { echo "ERROR: no Key Vault in $RG_NAME"; exit 1; }
fi

if [[ -z "$INGRESS_HOST" ]]; then
  PUBLIC_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$PUBLIC_IP" ]] || { echo "ERROR: no LB IP found. Is NGINX Ingress running?"; exit 1; }
  INGRESS_HOST="chat.${PUBLIC_IP}.nip.io"
fi

REDIRECT_URI="https://${INGRESS_HOST}/oauth2/callback"
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "=========================================="
echo "Phase 1E-c — oauth2-proxy app reg"
echo "  App name:     $APP_NAME"
echo "  Tenant:       $TENANT_ID"
echo "  Ingress host: $INGRESS_HOST"
echo "  Redirect URI: $REDIRECT_URI"
echo "  Key Vault:    $KV_NAME"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- 1. Create / fetch app reg ----------
echo ""
echo "[1/4] Creating / fetching app registration..."

APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [[ -z "$APP_ID" ]]; then
  echo "  Creating new app reg '$APP_NAME'..."
  APP_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  echo "  ✓ App ID: $APP_ID"

  # Wait briefly for AAD propagation before mutating.
  sleep 5
else
  echo "  ✓ Reusing existing app reg, App ID: $APP_ID"
fi

# ---------- 2. Ensure Web platform + redirect URI + ID-token flow ----------
echo "[2/4] Configuring Web platform + redirect URI..."

# Read current redirect URIs (web platform). PATCH to ADD ours if missing.
CURRENT_URIS=$(az ad app show --id "$APP_ID" --query "web.redirectUris" -o json)

if echo "$CURRENT_URIS" | grep -q "$REDIRECT_URI"; then
  echo "  ✓ Redirect URI already present"
else
  echo "  Adding redirect URI..."
  # Merge: existing URIs + our new one.
  NEW_URIS=$(echo "$CURRENT_URIS" | jq -c ". + [\"$REDIRECT_URI\"] | unique")
  # PATCH the web property + enable implicit ID token issuance (required by
  # OIDC oauth2-proxy with response_type=code id_token-style validations).
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$(az ad app show --id "$APP_ID" --query id -o tsv)" \
    --headers "Content-Type=application/json" \
    --body "{\"web\":{\"redirectUris\": $NEW_URIS, \"implicitGrantSettings\":{\"enableIdTokenIssuance\": true}}}" \
    --output none
  echo "  ✓ Redirect URI added"
fi

# Microsoft Graph User.Read delegated permission is included by default on app
# creation but explicit re-grant doesn't hurt for idempotency.

# ---------- 3. Generate / rotate client secret ----------
echo "[3/4] Generating client secret (24-month expiry)..."

# Each run creates a fresh secret. Old ones remain valid until expiry — for the
# lab that's fine; in production you'd revoke explicitly.
SECRET_END=$(date -u -v+24m '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -d '+24 months' '+%Y-%m-%dT%H:%M:%SZ')
CLIENT_SECRET=$(az ad app credential reset \
  --id "$APP_ID" \
  --display-name "oauth2-proxy-cookie" \
  --end-date "$SECRET_END" \
  --query password -o tsv)

# ---------- 4. Stash everything in KV + GH variables ----------
echo "[4/4] Storing values in Key Vault + GitHub variables..."
az keyvault secret set --vault-name "$KV_NAME" --name oauth2-proxy-client-id     --value "$APP_ID"        --output none
az keyvault secret set --vault-name "$KV_NAME" --name oauth2-proxy-client-secret --value "$CLIENT_SECRET" --output none

# Also generate the oauth2-proxy cookie secret (32 bytes base64, used to encrypt
# the session cookie). Random; rotating it logs everyone out.
COOKIE_SECRET=$(openssl rand -base64 32 | tr -d '\n' | head -c 32 | base64)
az keyvault secret set --vault-name "$KV_NAME" --name oauth2-proxy-cookie-secret --value "$COOKIE_SECRET" --output none

gh variable set OAUTH2_PROXY_APP_ID --body "$APP_ID" --repo "$GH_REPO" || true
gh variable set INGRESS_HOST        --body "$INGRESS_HOST" --repo "$GH_REPO" || true

echo ""
echo "=========================================="
echo "✓ oauth2-proxy app reg ready."
echo "  App ID:        $APP_ID"
echo "  Redirect URI:  $REDIRECT_URI"
echo ""
echo "  KV secrets:"
echo "    - oauth2-proxy-client-id"
echo "    - oauth2-proxy-client-secret  (24-month expiry)"
echo "    - oauth2-proxy-cookie-secret"
echo ""
echo "Next: ./scripts/07-deploy-oauth2-proxy.sh"
echo "=========================================="
