# ADR 0001 — Defer Defender for Containers sensor + Azure Policy add-on to Phase 3

**Status**: Accepted
**Date**: 2026-05-22
**Phase**: 1C

## Context

The Microsoft Defender for Cloud "Defender for Containers" plan, when enabled on a subscription, has multiple sub-components:

1. **Defender CSPM + agentless image scanning** — runs entirely in Microsoft's plane. Zero install on your AKS cluster. Free signals (recommendations, vulnerability findings on images in ACR).
2. **Defender sensor (DaemonSet)** — installed automatically on every AKS cluster in the subscription. Provides runtime threat detection (eBPF-based).
3. **Azure Policy for Kubernetes (Gatekeeper add-on)** — installed automatically on every AKS cluster. Provides admission control + posture policies.

By default, enabling the Defender for Containers plan causes #2 and #3 to be **auto-installed via Azure Policy** on every AKS cluster the subscription contains, including any new ones.

For Phase 1 of this lab, the goal is to **build a working DevOps pipeline first**, with **zero security gates**, so the contrast with Phase 2+ (where security layers are progressively added) is visible. Auto-installed Defender components on the AKS cluster would muddy that contrast.

## Decision

Keep the **Defender for Containers plan enabled** at the subscription level — we want the free signals (agentless image scanning + posture recommendations) flowing from day one.

But **explicitly disable** these two auto-install components in the plan settings:

- ❌ **Defender sensor** (DaemonSet)
- ❌ **Azure Policy for Kubernetes** (Gatekeeper add-on)

Both stay OFF until **Phase 3**, when they will be deliberately re-enabled as the "now I want runtime threat detection + admission control" milestone.

## How to verify the decision is in effect

```bash
# 1. Defender plan is ON
az security pricing show --name Containers --query "pricingTier" -o tsv
# Expected: Standard

# 2. Sensor is NOT running on the cluster
kubectl get ds -A | grep -i defender || echo "✓ no defender pods"

# 3. Azure Policy add-on is NOT running on the cluster
kubectl get ns gatekeeper-system 2>&1 | head -1
# Expected: Error from server (NotFound): namespaces "gatekeeper-system" not found

# 4. AKS cluster has azure_policy_enabled = false in Terraform
grep -A 1 "azure_policy_enabled" terraform/modules/aks/main.tf
# Expected: azure_policy_enabled = false
```

All four checks have already been verified at the end of Phase 1B.

## Why this matters (the security-engineer lens)

Most teams enable Defender plans without realizing they're now running Microsoft code in every workload pod's namespace and have policy engines intercepting every `kubectl apply`. That's fine in production — that's literally what you want — but it makes the lab less educational because Defender does so much automatically.

By staging it deliberately, you'll **feel the difference** between "no admission control" (Phase 1) and "Ratify + Gatekeeper rejecting unsigned images" (Phase 3). That's the lesson.

## Implementation note

The disabling is done in the Azure portal, not via Terraform:

**Defender for Cloud → Environment settings → subscription → Defender for Containers → Settings**
- Toggle "Defender sensor" → **Off**
- Toggle "Azure Policy for Kubernetes" → **Off**

This was completed before Phase 1B's `terraform apply` ran (so the AKS cluster never had these components installed). For future AKS clusters in the same subscription, the toggle persists — they will also not get auto-installed.

## When to re-enable

**Phase 3**: re-enable both as part of the "cluster & runtime security on AKS" milestone, alongside:
- Private AKS API server
- NetworkPolicy (default-deny)
- Pod Security Admission (restricted)
- Key Vault CSI driver
- Ratify admission controller + cosign verification
- Azure Front Door + WAF in front of n8n
- AOAI private endpoint

At that point, Defender's runtime detection becomes a meaningful signal — there's actual workload to defend, actual network policies to enforce, actual signed images to verify.
