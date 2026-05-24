#!/usr/bin/env bash
# Phase 1E-d — deploy the SPA, update oauth2-proxy for dual-mode, import + activate
# the n8n chat workflow.
#
# Idempotent.

set -euo pipefail

PREFIX="${PREFIX:-dsolab}"
RG_NAME="${RG_NAME:-rg-${PREFIX}-sea}"
NAMESPACE="${NAMESPACE:-n8n}"
GH_REPO="${GH_REPO:-NovelAMG/dsolab}"
KV_NAME="${KV_NAME:-}"
ACR_NAME="${ACR_NAME:-}"
IMAGE_TAG="${IMAGE_TAG:-}"

command -v az      >/dev/null || { echo "ERROR: az not found."; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found."; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az."; exit 1; }

if [[ -z "$KV_NAME" ]];  then KV_NAME=$(az keyvault list -g "$RG_NAME" --query "[0].name" -o tsv); fi
if [[ -z "$ACR_NAME" ]]; then ACR_NAME=$(az acr list      -g "$RG_NAME" --query "[0].name" -o tsv); fi
ACR_LOGIN_SERVER=$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="${ACR_LOGIN_SERVER}/dsolab/spa:latest"
fi

N8N_API_APP_URI=$(gh variable get N8N_API_APP_URI --repo "$GH_REPO")
# Audience is the URI minus the trailing slash (Entra emits aud=api://<appId> for v2 tokens
# requested as "api://<appId>/scope").
N8N_API_AUDIENCE="$N8N_API_APP_URI"

echo "=========================================="
echo "Phase 1E-d — deploy SPA + import workflow"
echo "  SPA image:      $IMAGE_TAG"
echo "  n8n-api audience: $N8N_API_AUDIENCE"
echo "  Namespace:      $NAMESPACE"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s"

# ---------- 1. Patch oauth2-proxy Secret with N8N_API_AUDIENCE ----------
echo ""
echo "[1/5] Adding N8N_API_AUDIENCE to oauth2-proxy-secrets..."
# Pull current secret values + add the new key, then re-apply.
CURRENT=$(kubectl get secret -n "$NAMESPACE" oauth2-proxy-secrets -o json)
NEW_VAL_B64=$(echo -n "$N8N_API_AUDIENCE" | base64)
echo "$CURRENT" | jq ".data[\"N8N_API_AUDIENCE\"] = \"$NEW_VAL_B64\"" | kubectl apply -f -

# ---------- 2. Apply oauth2-proxy with the new args (dual-mode) ----------
echo "[2/5] Re-applying oauth2-proxy (dual-mode: cookie + JWT)..."
kubectl apply -f "${K8S_DIR}/oauth2-proxy/deployment.yaml"
kubectl rollout restart deployment/oauth2-proxy -n "$NAMESPACE"
kubectl rollout status  deployment/oauth2-proxy -n "$NAMESPACE" --timeout=3m

# ---------- 3. Apply SPA Deployment + Service ----------
echo "[3/5] Applying SPA manifests..."
kubectl apply -f "${K8S_DIR}/spa/service.yaml"
kubectl apply -f "${K8S_DIR}/spa/deployment.yaml"
# Pin the actual image tag (not :latest in the YAML).
kubectl set image -n "$NAMESPACE" deployment/spa "spa=$IMAGE_TAG"
kubectl rollout status -n "$NAMESPACE" deployment/spa --timeout=5m

# ---------- 4. Create ConfigMap from the workflow JSON ----------
echo "[4/5] Creating/updating n8n-workflow-chat ConfigMap..."
WORKFLOW_FILE="${SCRIPT_DIR}/../n8n-workflows/chat.json"
[[ -f "$WORKFLOW_FILE" ]] || { echo "ERROR: $WORKFLOW_FILE missing"; exit 1; }

kubectl create configmap n8n-workflow-chat -n "$NAMESPACE" \
  --from-file=chat.json="$WORKFLOW_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------- 5. Run the import Job ----------
echo "[5/5] Running import-chat-workflow Job..."
# Re-create — Job names are immutable and we want a fresh run each invocation.
kubectl delete job -n "$NAMESPACE" import-chat-workflow --ignore-not-found
kubectl apply -f "${K8S_DIR}/n8n/workflow-import-job.yaml"

echo "  Waiting for Job to complete (max 3 min)..."
if ! kubectl wait --for=condition=complete -n "$NAMESPACE" job/import-chat-workflow --timeout=3m; then
  echo "ERROR: import Job failed. Logs:"
  kubectl logs -n "$NAMESPACE" job/import-chat-workflow --tail=80 || true
  echo ""
  echo "FALLBACK: import manually via the n8n UI:"
  echo "  1. Open https://chat.<ip>.nip.io/ and sign in"
  echo "  2. Workflows -> Import from File -> select n8n-workflows/chat.json"
  echo "  3. Toggle 'Active' on top right"
  exit 1
fi
echo ""
kubectl logs -n "$NAMESPACE" job/import-chat-workflow --tail=20 | sed 's/^/    /'

echo ""
echo "=========================================="
echo "✓ SPA + workflow deployed."
echo ""
kubectl get pods,svc -n "$NAMESPACE"
echo ""
echo "Test it:"
INGRESS_HOST=$(kubectl get ingress -n "$NAMESPACE" n8n -o jsonpath='{.spec.rules[0].host}')
echo "  1. Open https://${INGRESS_HOST}/ in a fresh InPrivate window"
echo "  2. Click 'Sign in with Microsoft' -> Entra popup"
echo "  3. Type a message, hit Send"
echo "  4. Watch the reply come back from gpt-4o (via n8n via WL identity)"
echo "=========================================="
