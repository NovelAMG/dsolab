#!/usr/bin/env bash
# One-time registration of Azure Resource Providers needed by Phase 1B+.
# Run this as a subscription Owner (your account, not the GitHub Actions MI).
#
# Why this exists: providers.tf sets `resource_provider_registrations = "none"`
# so the GH Actions MI (scoped to RG only) doesn't try (and fail) to register
# RPs at subscription scope. We pre-register exactly what we need, no more.
#
# Idempotent: re-registering an already-registered RP is a no-op.

set -euo pipefail

# RPs needed by our Terraform modules
PROVIDERS=(
  "Microsoft.ContainerService"       # AKS
  "Microsoft.ContainerRegistry"      # ACR
  "Microsoft.KeyVault"               # Key Vault
  "Microsoft.OperationalInsights"    # Log Analytics workspace
  "Microsoft.Insights"               # diagnostic settings, metrics
  "Microsoft.CognitiveServices"      # Azure OpenAI
  "Microsoft.DBforPostgreSQL"        # Postgres Flexible Server
  "Microsoft.ManagedIdentity"        # user-assigned MIs
  "Microsoft.Network"                # AKS managed VNet, future private endpoints
  "Microsoft.Compute"                # AKS VMSS nodes
  "Microsoft.Storage"                # Azure Files for AKS PVCs (Phase 1E)
  "Microsoft.Authorization"          # role assignments (UAA actions)
  "Microsoft.PolicyInsights"         # Defender posture findings (Phase 2A.1)
)

az account show >/dev/null 2>&1 || { echo "ERROR: not logged into az. Run 'az login'."; exit 1; }

SUB_NAME=$(az account show --query name -o tsv)
SUB_ID=$(az account show --query id -o tsv)

echo "Registering Resource Providers on subscription: $SUB_NAME ($SUB_ID)"
echo ""

for RP in "${PROVIDERS[@]}"; do
  STATE=$(az provider show --namespace "$RP" --query registrationState -o tsv 2>/dev/null || echo "NotFound")
  case "$STATE" in
    Registered)
      echo "  ✓ $RP — already Registered"
      ;;
    Registering)
      echo "  ⏳ $RP — Registering (in progress)"
      ;;
    *)
      echo "  → $RP — kicking off registration..."
      az provider register --namespace "$RP" --output none
      ;;
  esac
done

echo ""
echo "Waiting for all to reach 'Registered' state (typically ~30-60s each)..."
echo ""

for RP in "${PROVIDERS[@]}"; do
  printf "  %-35s " "$RP"
  while true; do
    STATE=$(az provider show --namespace "$RP" --query registrationState -o tsv)
    if [[ "$STATE" == "Registered" ]]; then
      echo "✓ Registered"
      break
    fi
    sleep 5
  done
done

echo ""
echo "✓ All Resource Providers registered. You can now push your Phase 1B PR — terraform plan should succeed."
