#!/usr/bin/env bash
# Phase 1E-b — deploy n8n to AKS.
#
# What this does:
#   1. Reads n8n's DB password + encryption key + Postgres FQDN from Key Vault.
#   2. Creates/updates a K8s Secret 'n8n-secrets' that the Deployment consumes
#      via envFrom (no plaintext values in any YAML file).
#   3. Applies the PVC, Deployment, Service.
#   4. Waits for the n8n pod to become Ready.
#   5. Prints the `kubectl port-forward` command to open the n8n UI.
#
# Prereqs:
#   - scripts/03-cluster-prereqs.sh applied (n8n namespace + SA exist)
#   - scripts/04-postgres-init.sh applied (n8n DB + role + KV secrets exist)
#
# Idempotent. Re-running picks up rotated secrets and re-rolls the Deployment.

set -euo pipefail

# ---------- Config ----------
PREFIX="${PREFIX:-dsolab}"
RG_NAME="${RG_NAME:-rg-${PREFIX}-sea}"
NAMESPACE="${NAMESPACE:-n8n}"
KV_NAME="${KV_NAME:-}"

# ---------- Pre-flight ----------
command -v az      >/dev/null || { echo "ERROR: az not found.";      exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found."; exit 1; }

az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az."; exit 1; }
kubectl get sa n8n -n "$NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: ServiceAccount n8n/n8n missing. Run scripts/03-cluster-prereqs.sh first."
  exit 1
}

if [[ -z "$KV_NAME" ]]; then
  KV_NAME=$(az keyvault list -g "$RG_NAME" --query "[0].name" -o tsv)
  [[ -n "$KV_NAME" ]] || { echo "ERROR: no Key Vault found in $RG_NAME"; exit 1; }
fi

echo "=========================================="
echo "Phase 1E-b — deploy n8n"
echo "  Key Vault:  $KV_NAME"
echo "  Namespace:  $NAMESPACE"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- 1. Read secrets from KV ----------
echo ""
echo "[1/4] Reading n8n secrets from Key Vault..."
PG_FQDN=$(az keyvault secret show --vault-name "$KV_NAME" --name postgres-fqdn         --query value -o tsv)
N8N_DB_PASS=$(az keyvault secret show --vault-name "$KV_NAME" --name n8n-db-password    --query value -o tsv)
N8N_ENC_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name n8n-encryption-key --query value -o tsv)

if [[ -z "$N8N_DB_PASS" || -z "$N8N_ENC_KEY" ]]; then
  echo "ERROR: required KV secrets missing. Run scripts/04-postgres-init.sh first."
  exit 1
fi

# ---------- 2. Create/update K8s Secret ----------
echo "[2/4] Creating/updating K8s Secret 'n8n-secrets'..."
kubectl create secret generic n8n-secrets -n "$NAMESPACE" \
  --from-literal=DB_POSTGRESDB_HOST="$PG_FQDN" \
  --from-literal=DB_POSTGRESDB_DATABASE="n8n" \
  --from-literal=DB_POSTGRESDB_USER="n8n" \
  --from-literal=DB_POSTGRESDB_PASSWORD="$N8N_DB_PASS" \
  --from-literal=N8N_ENCRYPTION_KEY="$N8N_ENC_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------- 3. Apply manifests ----------
echo "[3/4] Applying manifests (PVC, Service, Deployment)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s/n8n"

kubectl apply -f "${K8S_DIR}/pvc.yaml"
kubectl apply -f "${K8S_DIR}/service.yaml"
kubectl apply -f "${K8S_DIR}/deployment.yaml"

# Force a rollout in case the only thing that changed is the Secret contents
# (kubectl apply on the Deployment is a no-op if its spec didn't change).
kubectl rollout restart deployment/n8n -n "$NAMESPACE"

# ---------- 4. Wait + verify ----------
echo "[4/4] Waiting for n8n pod to become Ready (up to 5 min — first boot is slow on B2s)..."
if ! kubectl rollout status deployment/n8n -n "$NAMESPACE" --timeout=5m; then
  echo ""
  echo "ERROR: rollout didn't finish. Recent events:"
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -15
  echo ""
  echo "Pod logs:"
  kubectl logs -n "$NAMESPACE" -l app=n8n --tail=50 || true
  exit 1
fi

echo ""
echo "=========================================="
echo "✓ n8n is running."
echo ""
kubectl get pods,svc,pvc -n "$NAMESPACE"
echo ""
echo "Open n8n in your browser:"
echo "  kubectl port-forward -n $NAMESPACE svc/n8n 5678:5678"
echo "  then visit http://localhost:5678"
echo ""
echo "On first visit you'll see n8n's setup wizard — create an owner account."
echo "=========================================="
