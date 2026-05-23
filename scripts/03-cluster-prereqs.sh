#!/usr/bin/env bash
# Phase 1E-a — cluster prerequisites.
#
# What this script installs on AKS (idempotent — safe to re-run):
#   1. NGINX Ingress Controller       (public LoadBalancer → cluster entry point)
#   2. cert-manager + CRDs            (auto-issues TLS certs)
#   3. Let's Encrypt staging ClusterIssuer (HTTP-01 via the ingress)
#   4. `n8n` namespace + ServiceAccount annotated for Azure Workload Identity
#
# Why Helm + kubectl instead of Terraform?
#   - Helm chart CRDs (cert-manager) cause TF state drift loops.
#   - Cluster add-ons get updated independently of infra; pinning them in TF
#     means a tf-apply just to bump a chart version.
#   - kubectl + helm IS the K8s-native UX; staying close to it makes 1E-{b,c,d}
#     a lot easier to debug.
#
# Prereqs:
#   - Terraform Phase 1B + 1D already applied (cluster + MI exist)
#   - `az aks get-credentials` already run (kubectl context points at our cluster)
#   - helm + kubectl installed locally

set -euo pipefail

# ---------- Config ----------
PREFIX="${PREFIX:-dsolab}"
RG_NAME="${RG_NAME:-rg-${PREFIX}-sea}"
AKS_NAME="${AKS_NAME:-aks-${PREFIX}-sea}"
N8N_MI_NAME="${N8N_MI_NAME:-mi-n8n-aoai-${PREFIX}}"

NGINX_NAMESPACE="ingress-nginx"
CERT_MGR_NAMESPACE="cert-manager"
N8N_NAMESPACE="n8n"
N8N_SA="n8n"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
NGINX_CHART_VERSION="${NGINX_CHART_VERSION:-4.11.3}"

LE_EMAIL="${LE_EMAIL:-}"  # required, no default — see runbook

# ---------- Pre-flight ----------
command -v helm    >/dev/null || { echo "ERROR: helm not found.    Install: brew install helm";    exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found. Install: az aks install-cli or brew install kubernetes-cli"; exit 1; }
command -v az      >/dev/null || { echo "ERROR: az not found.      Install: brew install azure-cli"; exit 1; }

if [[ -z "$LE_EMAIL" ]]; then
  echo "ERROR: LE_EMAIL is required (used by Let's Encrypt for cert expiry notices)."
  echo "  Example: LE_EMAIL=you@example.com $0"
  exit 1
fi

# Sanity-check we're pointed at the right cluster
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$CURRENT_CTX" != "$AKS_NAME" ]]; then
  echo "WARN: kubectl context is '$CURRENT_CTX', expected '$AKS_NAME'."
  echo "      Run: az aks get-credentials -g $RG_NAME -n $AKS_NAME --overwrite-existing"
  read -p "Continue anyway? (y/N) " -n 1 -r CONFIRM
  echo
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# Resolve the n8n MI's client ID (used to annotate the K8s SA — this is the
# "magic glue" of workload identity: the webhook sees this label/annotation pair
# and injects a federated-token volume + env vars into pods that use this SA).
N8N_MI_CLIENT_ID=$(az identity show -g "$RG_NAME" -n "$N8N_MI_NAME" --query clientId -o tsv 2>/dev/null || true)
if [[ -z "$N8N_MI_CLIENT_ID" ]]; then
  echo "ERROR: managed identity '$N8N_MI_NAME' not found in '$RG_NAME'."
  echo "       Run Phase 1D Terraform first."
  exit 1
fi
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "=========================================="
echo "Phase 1E-a — cluster prereqs"
echo "  Cluster:        $AKS_NAME"
echo "  n8n MI clientId: $N8N_MI_CLIENT_ID"
echo "  Tenant:         $TENANT_ID"
echo "  cert-manager:   $CERT_MANAGER_VERSION"
echo "  NGINX chart:    $NGINX_CHART_VERSION"
echo "  LE email:       $LE_EMAIL"
echo "=========================================="
read -p "Proceed? (y/N) " -n 1 -r CONFIRM
echo
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---------- 1. Helm repos ----------
echo ""
echo "[1/5] Adding/updating Helm repos..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
helm repo add jetstack      https://charts.jetstack.io                 --force-update >/dev/null
helm repo update >/dev/null

# ---------- 2. NGINX Ingress Controller ----------
echo "[2/5] Installing NGINX Ingress Controller..."
# - controller.service.type=LoadBalancer creates an Azure Public Load Balancer in the AKS node RG.
# - controller.replicaCount=1 — our 2x B2s nodes (2 vCPU / 4 GB) can't fit 2 NGINX replicas
#   alongside AKS system pods + Gatekeeper + Defender. Going 2 replicas causes the 2nd pod
#   to wedge (slow image pulls, probe timeouts). 1 replica is fine for a lab. See ADR 0011.
# - externalTrafficPolicy=Local — Azure LB only routes to nodes that have a pod, instead of
#   round-robining to all nodes (Cluster policy). On a small cluster where some nodes are
#   metrics-unhealthy, Cluster policy causes ~50% blackhole rate. See ADR 0011.
# - allowSnippetAnnotations=false (CVE-2025-1974 default in modern charts).
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "$NGINX_NAMESPACE" \
  --create-namespace \
  --version "$NGINX_CHART_VERSION" \
  --set controller.replicaCount=1 \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Local \
  --set controller.allowSnippetAnnotations=false \
  --set controller.metrics.enabled=true \
  --wait \
  --timeout 8m

# ---------- 3. cert-manager ----------
echo "[3/5] Installing cert-manager (with CRDs)..."
# installCRDs=true is the easy path. For prod you'd kubectl apply the CRD YAML
# separately so cert-manager upgrades don't churn the CRDs — fine for a lab.
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "$CERT_MGR_NAMESPACE" \
  --create-namespace \
  --version "$CERT_MANAGER_VERSION" \
  --set installCRDs=true \
  --wait \
  --timeout 5m

# ---------- 4. Let's Encrypt staging ClusterIssuer ----------
echo "[4/5] Applying Let's Encrypt staging ClusterIssuer..."
# Staging = relaxed rate limits, untrusted certs (browser warns). Use this while
# you debug your ingress rules; flip to letsencrypt-prod only when everything works.
# HTTP-01 challenge uses the nginx ingress class we just installed.
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${LE_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

# ---------- 5. n8n namespace + ServiceAccount ----------
echo "[5/5] Creating n8n namespace + ServiceAccount with workload-identity annotation..."
# The label + annotation are what the Azure Workload Identity webhook (built into
# AKS when workload_identity_enabled=true) watches for. Pods that use this SA
# AND carry the label `azure.workload.identity/use: "true"` get a projected
# federated-token volume + AZURE_* env vars auto-injected.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${N8N_NAMESPACE}
  labels:
    purpose: workload
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${N8N_SA}
  namespace: ${N8N_NAMESPACE}
  annotations:
    azure.workload.identity/client-id: "${N8N_MI_CLIENT_ID}"
    azure.workload.identity/tenant-id: "${TENANT_ID}"
  labels:
    azure.workload.identity/use: "true"
EOF

# ---------- Done ----------
echo ""
echo "=========================================="
echo "✓ Cluster prereqs installed."
echo ""
echo "Wait ~60s for the Azure LB to provision a public IP, then check:"
echo ""
echo "  kubectl get svc -n $NGINX_NAMESPACE ingress-nginx-controller \\"
echo "    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{\"\\n\"}'"
echo ""
echo "  kubectl get pods -n $CERT_MGR_NAMESPACE"
echo "  kubectl get clusterissuer letsencrypt-staging"
echo "  kubectl get sa -n $N8N_NAMESPACE ${N8N_SA} -o yaml"
echo ""
echo "Next: open http://<that-ip>/ — you should see NGINX's default 404 page."
echo "      That 404 is the win — it means the ingress is reachable."
echo "=========================================="
