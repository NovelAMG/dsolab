#!/usr/bin/env bash
# Phase 1E-d — build the SPA image and push to ACR.
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │  DEV-ITERATION ONLY since Phase 3.6 (2026-05-24).                   │
# │                                                                     │
# │  Production builds run in CI via .github/workflows/build-spa.yml    │
# │  on every push to main that touches spa/**. Those images are signed │
# │  with GitHub OIDC and will be the only ones Defender Image          │
# │  Integrity (Phase 3.7) admits to the n8n namespace.                 │
# │                                                                     │
# │  Use this script for fast feedback while developing. Images pushed  │
# │  by this script are NOT signed and will be REJECTED by admission    │
# │  once 3.7 is on — that's by design. See ADR 0017.                   │
# └─────────────────────────────────────────────────────────────────────┘
#
# Also adds the production redirect URI to the SPA app reg if missing.
#
# What this does:
#   1. Adds https://<INGRESS_HOST>/auth/callback to the SPA app reg (idempotent)
#   2. `az acr login` (uses your Entra creds, not the admin user)
#   3. docker build (multi-stage, bakes VITE_* env vars into the bundle)
#   4. docker push to acrdsolabxsqb.azurecr.io/dsolab/spa:<SHA>
#   5. Prints the tagged image so scripts/09 can deploy it
#
# Re-running rebuilds. Tag is the git short SHA, so re-runs without source
# changes produce the same tag (idempotent push).

set -euo pipefail

PREFIX="${PREFIX:-dsolab}"
RG_NAME="${RG_NAME:-rg-${PREFIX}-sea}"
GH_REPO="${GH_REPO:-NovelAMG/dsolab}"
ACR_NAME="${ACR_NAME:-}"
INGRESS_HOST="${INGRESS_HOST:-}"

command -v az     >/dev/null || { echo "ERROR: az not found.";     exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not found. Start Docker Desktop or install."; exit 1; }
command -v jq     >/dev/null || { echo "ERROR: jq not found. brew install jq"; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az."; exit 1; }

if [[ -z "$ACR_NAME" ]]; then
  ACR_NAME=$(az acr list -g "$RG_NAME" --query "[0].name" -o tsv)
fi
ACR_LOGIN_SERVER=$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)

if [[ -z "$INGRESS_HOST" ]]; then
  PUBLIC_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  INGRESS_HOST="chat.${PUBLIC_IP}.nip.io"
fi

SPA_APP_ID=$(gh variable get SPA_APP_ID --repo "$GH_REPO")
N8N_API_APP_URI=$(gh variable get N8N_API_APP_URI --repo "$GH_REPO")
TENANT_ID=$(az account show --query tenantId -o tsv)
PROD_REDIRECT="https://${INGRESS_HOST}/auth/callback"

GIT_SHA=$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || echo "dev")
IMAGE_TAG="${ACR_LOGIN_SERVER}/dsolab/spa:${GIT_SHA}"

echo "=========================================="
echo "Phase 1E-d — build & push SPA"
echo "  ACR:            $ACR_LOGIN_SERVER"
echo "  SPA app ID:     $SPA_APP_ID"
echo "  n8n-api scope:  ${N8N_API_APP_URI}/access_as_user"
echo "  Ingress host:   $INGRESS_HOST"
echo "  Redirect URI:   $PROD_REDIRECT"
echo "  Image tag:      $IMAGE_TAG"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- 1. Add prod redirect URI to SPA app reg ----------
echo ""
echo "[1/4] Ensuring SPA app reg has the prod redirect URI..."
CURRENT_URIS=$(az ad app show --id "$SPA_APP_ID" --query "spa.redirectUris" -o json)
if echo "$CURRENT_URIS" | grep -q "$PROD_REDIRECT"; then
  echo "  ✓ Already present"
else
  NEW_URIS=$(echo "$CURRENT_URIS" | jq -c ". + [\"$PROD_REDIRECT\"] | unique")
  APP_OBJECT_ID=$(az ad app show --id "$SPA_APP_ID" --query id -o tsv)
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$APP_OBJECT_ID" \
    --headers "Content-Type=application/json" \
    --body "{\"spa\":{\"redirectUris\": $NEW_URIS}}" \
    --output none
  echo "  ✓ Added $PROD_REDIRECT"
fi

# ---------- 2. ACR login ----------
echo "[2/4] Logging into ACR..."
az acr login -n "$ACR_NAME" --output none

# ---------- 3. Build (with build args) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPA_DIR="${SCRIPT_DIR}/../spa"

echo "[3/4] Building SPA image..."
# Build for linux/amd64 explicitly — Apple Silicon would default to arm64 which
# fails to schedule on our amd64 AKS nodes.
docker buildx build \
  --platform linux/amd64 \
  --load \
  --build-arg VITE_SPA_CLIENT_ID="$SPA_APP_ID" \
  --build-arg VITE_TENANT_ID="$TENANT_ID" \
  --build-arg VITE_N8N_API_SCOPE="${N8N_API_APP_URI}/access_as_user" \
  --build-arg VITE_REDIRECT_URI="$PROD_REDIRECT" \
  -t "$IMAGE_TAG" \
  -t "${ACR_LOGIN_SERVER}/dsolab/spa:latest" \
  "$SPA_DIR"

# ---------- 4. Push ----------
echo "[4/4] Pushing $IMAGE_TAG ..."
docker push "$IMAGE_TAG"
docker push "${ACR_LOGIN_SERVER}/dsolab/spa:latest"

echo ""
echo "=========================================="
echo "✓ SPA pushed."
echo "  Image:    $IMAGE_TAG"
echo "  Also as: ${ACR_LOGIN_SERVER}/dsolab/spa:latest"
echo ""
echo "Next: ./scripts/09-deploy-spa-and-workflow.sh"
echo "  (or with explicit image:  IMAGE_TAG=$IMAGE_TAG ./scripts/09-deploy-spa-and-workflow.sh)"
echo "=========================================="
