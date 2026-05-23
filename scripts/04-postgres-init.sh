#!/usr/bin/env bash
# Phase 1E-b — Postgres bootstrap for n8n.
#
# What this does:
#   1. Reads the SQL admin password + Postgres FQDN from Key Vault.
#   2. Generates a strong random password for n8n's SQL role.
#   3. Generates a random 32-byte hex string for n8n's encryption key (used by n8n
#      internally to encrypt stored credentials in its DB; if lost, all
#      stored creds become unreadable).
#   4. Stores both new secrets in Key Vault (`n8n-db-password`, `n8n-encryption-key`).
#   5. Applies a one-shot K8s Job that connects to Postgres and creates:
#        - role `n8n` with the generated password
#        - database `n8n` owned by `n8n`
#        - grants
#   6. Waits for the job to complete, prints logs, cleans up the temp K8s Secret.
#
# Idempotent. Re-running rotates the n8n DB password (which is fine in this phase
# because n8n hasn't been deployed yet; scripts/05 reads the current KV value).

set -euo pipefail

# ---------- Config ----------
PREFIX="${PREFIX:-dsolab}"
RG_NAME="${RG_NAME:-rg-${PREFIX}-sea}"
NAMESPACE="${NAMESPACE:-n8n}"
KV_NAME="${KV_NAME:-}"  # autodetect if blank

# ---------- Pre-flight ----------
command -v az      >/dev/null || { echo "ERROR: az not found.";      exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found."; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl not found."; exit 1; }

az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az."; exit 1; }
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || {
  echo "ERROR: namespace '$NAMESPACE' missing. Run scripts/03-cluster-prereqs.sh first."
  exit 1
}

# Auto-detect Key Vault if not set.
if [[ -z "$KV_NAME" ]]; then
  KV_NAME=$(az keyvault list -g "$RG_NAME" --query "[0].name" -o tsv)
  [[ -n "$KV_NAME" ]] || { echo "ERROR: no Key Vault found in $RG_NAME"; exit 1; }
fi

echo "=========================================="
echo "Phase 1E-b — Postgres init"
echo "  Key Vault:  $KV_NAME"
echo "  Namespace:  $NAMESPACE"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- 1. Read admin creds from KV ----------
echo ""
echo "[1/5] Reading SQL admin credentials from Key Vault..."
PG_ADMIN_USER=$(az keyvault secret show --vault-name "$KV_NAME" --name postgres-admin-login --query value -o tsv)
PG_ADMIN_PASS=$(az keyvault secret show --vault-name "$KV_NAME" --name postgres-admin-password --query value -o tsv)
PG_FQDN=$(az keyvault secret show --vault-name "$KV_NAME" --name postgres-fqdn --query value -o tsv)
echo "  Admin user: $PG_ADMIN_USER"
echo "  Host:       $PG_FQDN"

# ---------- 2 + 3. Generate n8n DB password + encryption key ----------
echo "[2/5] Generating n8n DB password + encryption key..."
# Avoid characters that need escaping in a shell heredoc (no single-quote, no $).
N8N_DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=$\047' | head -c 32)
N8N_ENC_KEY=$(openssl rand -hex 32)

# ---------- 4. Stash new secrets in KV ----------
echo "[3/5] Stashing new secrets in Key Vault..."
az keyvault secret set --vault-name "$KV_NAME" --name n8n-db-password   --value "$N8N_DB_PASSWORD" --output none
az keyvault secret set --vault-name "$KV_NAME" --name n8n-encryption-key --value "$N8N_ENC_KEY"     --output none
echo "  ✓ n8n-db-password, n8n-encryption-key saved"

# ---------- 5. Run the init Job ----------
echo "[4/5] Creating temp K8s Secret 'postgres-bootstrap' for the init job..."
# Use --dry-run to make the Secret create idempotent (rotates contents on re-run).
kubectl create secret generic postgres-bootstrap -n "$NAMESPACE" \
  --from-literal=PG_HOST="$PG_FQDN" \
  --from-literal=PG_ADMIN_USER="$PG_ADMIN_USER" \
  --from-literal=PG_ADMIN_PASSWORD="$PG_ADMIN_PASS" \
  --from-literal=N8N_DB_PASSWORD="$N8N_DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[5/5] Running the postgres-init Job..."
# Delete any previous run (Job name is fixed → re-creates are blocked otherwise).
kubectl delete job -n "$NAMESPACE" postgres-init --ignore-not-found

# Apply the Job manifest from the repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -f "${SCRIPT_DIR}/../k8s/n8n/init-job.yaml"

echo "  Waiting for job to complete (max 2 min)..."
if ! kubectl wait --for=condition=complete -n "$NAMESPACE" job/postgres-init --timeout=2m; then
  echo "ERROR: init job failed. Logs:"
  kubectl logs -n "$NAMESPACE" job/postgres-init --tail=100
  exit 1
fi

echo ""
echo "  Job logs:"
kubectl logs -n "$NAMESPACE" job/postgres-init --tail=20 | sed 's/^/    /'

# ---------- Cleanup ----------
echo ""
echo "Cleaning up temp bootstrap secret..."
kubectl delete secret -n "$NAMESPACE" postgres-bootstrap --ignore-not-found

echo ""
echo "=========================================="
echo "✓ Postgres ready."
echo "  Database: n8n"
echo "  Role:     n8n"
echo "  Password: stored in Key Vault as 'n8n-db-password'"
echo "  Enc key:  stored in Key Vault as 'n8n-encryption-key'"
echo ""
echo "Next: ./scripts/05-deploy-n8n.sh"
echo "=========================================="
