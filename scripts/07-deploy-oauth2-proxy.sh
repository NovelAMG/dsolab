#!/usr/bin/env bash
# Phase 1E-c — deploy oauth2-proxy + Ingress + cert-manager Cert + update n8n config.
#
# What this does:
#   1. Reads oauth2-proxy app reg id/secret + cookie secret from KV.
#   2. Creates K8s Secret `oauth2-proxy-secrets` with the OIDC config.
#   3. Creates / updates ConfigMap `n8n-config` with the public hostname so
#      n8n knows its own URL (webhook URLs, editor redirects).
#   4. Applies oauth2-proxy Deployment + Service.
#   5. Renders & applies the Ingress (substituting $INGRESS_HOST).
#   6. Restarts the n8n Deployment so it picks up the new ConfigMap.
#   7. Waits for cert-manager to issue the LE-staging certificate.
#   8. Smokes the new URL.
#
# Prereqs:
#   - scripts/03-cluster-prereqs.sh (NGINX + cert-manager + n8n ns)
#   - scripts/04-postgres-init.sh + scripts/05-deploy-n8n.sh (n8n running)
#   - scripts/06-create-oauth2-proxy-app.sh (Entra app reg + KV secrets)
#
# Idempotent.

set -euo pipefail

# ---------- Config ----------
PREFIX="${PREFIX:-dsolab}"
RG_NAME="${RG_NAME:-rg-${PREFIX}-sea}"
NAMESPACE="${NAMESPACE:-n8n}"
KV_NAME="${KV_NAME:-}"
INGRESS_HOST="${INGRESS_HOST:-}"

# ---------- Pre-flight ----------
command -v az      >/dev/null || { echo "ERROR: az not found."; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found."; exit 1; }
command -v envsubst >/dev/null || { echo "ERROR: envsubst not found. brew install gettext"; exit 1; }

az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az."; exit 1; }

if [[ -z "$KV_NAME" ]]; then
  KV_NAME=$(az keyvault list -g "$RG_NAME" --query "[0].name" -o tsv)
fi

if [[ -z "$INGRESS_HOST" ]]; then
  PUBLIC_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$PUBLIC_IP" ]] || { echo "ERROR: no LB IP. Is NGINX Ingress running?"; exit 1; }
  INGRESS_HOST="chat.${PUBLIC_IP}.nip.io"
fi

# Sanity-check the app reg has been created
APP_ID=$(az keyvault secret show --vault-name "$KV_NAME" --name oauth2-proxy-client-id --query value -o tsv 2>/dev/null || true)
if [[ -z "$APP_ID" ]]; then
  echo "ERROR: oauth2-proxy-client-id missing in KV. Run scripts/06-create-oauth2-proxy-app.sh first."
  exit 1
fi

TENANT_ID=$(az account show --query tenantId -o tsv)

echo "=========================================="
echo "Phase 1E-c — deploy oauth2-proxy + Ingress"
echo "  Ingress host:  $INGRESS_HOST"
echo "  oauth2-proxy:  appId=$APP_ID"
echo "  Tenant:        $TENANT_ID"
echo "  Cert issuer:   letsencrypt-staging"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- 1. Fetch secrets from KV ----------
echo ""
echo "[1/7] Reading secrets from Key Vault..."
CLIENT_SECRET=$(az keyvault secret show --vault-name "$KV_NAME" --name oauth2-proxy-client-secret --query value -o tsv)
COOKIE_SECRET=$(az keyvault secret show --vault-name "$KV_NAME" --name oauth2-proxy-cookie-secret --query value -o tsv)
REDIRECT_URL="https://${INGRESS_HOST}/oauth2/callback"
ISSUER_URL="https://login.microsoftonline.com/${TENANT_ID}/v2.0"

# ---------- 2. Create K8s Secret for oauth2-proxy ----------
echo "[2/7] Creating/updating oauth2-proxy-secrets..."
kubectl create secret generic oauth2-proxy-secrets -n "$NAMESPACE" \
  --from-literal=OAUTH2_PROXY_CLIENT_ID="$APP_ID" \
  --from-literal=OAUTH2_PROXY_CLIENT_SECRET="$CLIENT_SECRET" \
  --from-literal=OAUTH2_PROXY_COOKIE_SECRET="$COOKIE_SECRET" \
  --from-literal=OAUTH2_PROXY_REDIRECT_URL="$REDIRECT_URL" \
  --from-literal=OIDC_ISSUER_URL="$ISSUER_URL" \
  --from-literal=INGRESS_HOST="$INGRESS_HOST" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------- 3. ConfigMap for n8n's public URL ----------
echo "[3/7] Creating/updating n8n-config ConfigMap..."
kubectl create configmap n8n-config -n "$NAMESPACE" \
  --from-literal=N8N_HOST="$INGRESS_HOST" \
  --from-literal=N8N_PROTOCOL="https" \
  --from-literal=WEBHOOK_URL="https://${INGRESS_HOST}/" \
  --from-literal=N8N_PROXY_HOPS="1" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------- 4. Apply oauth2-proxy ----------
echo "[4/7] Applying oauth2-proxy Deployment + Service..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s"

kubectl apply -f "${K8S_DIR}/oauth2-proxy/service.yaml"
kubectl apply -f "${K8S_DIR}/oauth2-proxy/deployment.yaml"
kubectl rollout restart deployment/oauth2-proxy -n "$NAMESPACE"

# ---------- 5. Apply Ingress (templated) ----------
echo "[5/7] Applying Ingress (host=$INGRESS_HOST)..."
INGRESS_HOST="$INGRESS_HOST" envsubst < "${K8S_DIR}/n8n/ingress.yaml" | kubectl apply -f -

# ---------- 6. Restart n8n so it picks up the new ConfigMap ----------
echo "[6/7] Restarting n8n to pick up new hostname config..."
kubectl rollout restart deployment/n8n -n "$NAMESPACE"

echo "  Waiting for n8n rollout..."
kubectl rollout status deployment/n8n -n "$NAMESPACE" --timeout=5m

echo "  Waiting for oauth2-proxy rollout..."
kubectl rollout status deployment/oauth2-proxy -n "$NAMESPACE" --timeout=2m

# ---------- 7. Wait for cert + smoke test ----------
echo "[7/7] Waiting for cert-manager to issue the TLS certificate..."
# cert-manager creates a Certificate, then an Order, then a Challenge against
# Let's Encrypt. Whole flow usually completes in 30-90s when HTTP-01 works.
for i in $(seq 1 60); do
  READY=$(kubectl get certificate -n "$NAMESPACE" n8n-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [[ "$READY" == "True" ]]; then
    echo "  ✓ Certificate Ready"
    break
  fi
  echo "    ...waiting ($i/60)"
  sleep 5
done

if [[ "$READY" != "True" ]]; then
  echo ""
  echo "WARN: cert not yet Ready. Diagnose with:"
  echo "  kubectl describe certificate -n $NAMESPACE n8n-tls"
  echo "  kubectl describe order -n $NAMESPACE"
  echo "  kubectl describe challenge -n $NAMESPACE"
fi

echo ""
echo "=========================================="
echo "✓ oauth2-proxy + Ingress deployed."
echo ""
kubectl get pods,svc,ingress -n "$NAMESPACE"
echo ""
echo "Test the URL in your browser:"
echo "  https://${INGRESS_HOST}/"
echo ""
echo "Expected:"
echo "  1. Browser warns about untrusted cert (LE staging) — click 'proceed'"
echo "  2. Redirect to login.microsoftonline.com"
echo "  3. Sign in with your Entra account"
echo "  4. Land on n8n's login page (n8n has its own auth on top)"
echo "  5. Sign in with the owner you set up in 1E-b"
echo "=========================================="
