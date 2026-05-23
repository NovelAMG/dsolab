# ADR 0013: Scale AKS to 3 nodes — Defender + Gatekeeper overhead leaves no room

- **Status**: Accepted
- **Date**: 2026-05-23
- **Phase**: 1E-b (discovered during first n8n schedule attempt)

## Context

Phase 1B sized the cluster at **2 × Standard_B2s** (2 vCPU, 4 GiB RAM each)
on the assumption that a small SPA + n8n + oauth2-proxy + ingress = ~1 GiB
of workload memory total, easily fitting in ~8 GiB of cluster capacity
minus AKS system pods (estimated ~1.5 GiB).

Reality on this cluster:

| Auto-injected pod | Memory request | Why we have it |
|---|---|---|
| `defender-admission-controller` | **512 Mi** | Defender for Containers (ADR 0001 says "off"; CSPM re-installs anyway) |
| `gatekeeper-controller` | 256 Mi | Azure Policy add-on (ADR 0001 disabled; CSPM re-installs) |
| `gatekeeper-audit` | 256 Mi | Azure Policy add-on |
| `azure-cns` (DaemonSet) | 250 Mi × N | Azure CNI |
| `ama-logs` (DaemonSet) | 50–325 Mi × N | Container Insights (we want this) |
| `microsoft-defender-collector-*` | 32–128 Mi × N | Defender for Cloud agents |
| Cilium + CSI drivers + cloud-node-manager | ~150 Mi × N | AKS required |

**Per-node baseline before any workload: ~2.6 GiB requested.** B2s
allocatable is ~2.8 GiB. That's ~94% committed on every node, before we
schedule a single application pod.

When trying to deploy n8n (request 384 Mi):

```text
Warning FailedScheduling: 0/2 nodes are available: 1 Insufficient memory,
                          1 node(s) were unschedulable.
```

We can't reduce Defender/Gatekeeper consumption — it's enforced from outside
the cluster.

## Decision

Scale the cluster from 2 → 3 nodes. The third node provides ~1.4 GiB free
memory after Defender/Gatekeeper baseline, which is enough room for n8n +
oauth2-proxy + the SPA pod planned for 1E-c/d.

Additionally:

- Cordon and accept that one node (`vmss000002`) is in a wedged state with
  metrics-server unable to reach it. Restart attempts via
  `az vmss restart --instance-ids 2` did not recover it. Phase 4 will
  delete this instance and let AKS reprovision.

## Cost impact

- Before: 2 × B2s ≈ $60/mo
- After:  3 × B2s ≈ $90/mo
- **Delta: +$30/mo (~+50% on compute, ~+15% on total lab budget)**

Still well within the $200/mo lab budget. Phase 4 may revisit by
introducing a dedicated `user` nodepool (B4ms) for workloads while the
`system` pool stays small for AKS overhead — a more efficient pattern at
this scale.

## Alternatives considered

1. **Disable Defender plans.** Out of scope — they're enforced at MG /
   subscription level by org policy and our lab inherits them. Disabling
   would also defeat the whole point of Phase 3 (demonstrating the
   Defender flow).
2. **Upgrade to B4ms (2 × 4 vCPU / 16 GiB).** Larger blast radius if one
   node dies; +$60/mo instead of +$30. Considered for Phase 4 once we
   have a separate user nodepool.
3. **Move n8n to Container Apps.** Defeats the "n8n on AKS as a teaching
   demo" goal; also Container Apps + n8n's filesystem dependency is
   awkward.
4. **Reduce n8n memory requests below 384 Mi.** n8n's pg-node + workflow
   engine genuinely needs ~300 Mi steady-state; requesting less risks
   OOMKilled during workflow execution.

## Consequences

**Positive:**

- n8n schedules in seconds.
- Future workload pods (oauth2-proxy ~50 Mi, SPA nginx ~30 Mi) fit easily.
- One node failure (we already have one) no longer blocks all scheduling.

**Negative:**

- $30/mo recurring cost increase.
- The wedged `vmss000002` is still sitting there — kubelet thinks it's
  Ready but it's untrustworthy. Documented; replacement deferred.

## Verification

```bash
kubectl get nodes
# Expect: 3 nodes, all Ready

az aks show -g rg-dsolab-sea -n aks-dsolab-sea --query "agentPoolProfiles[0].count"
# Expect: 3
```

## Related

- ADR 0001 — Defender sensor deferred to Phase 3 (but CSPM-injected
  components are clearly not deferred).
- ADR 0011 — NGINX single-replica + Local traffic policy (same root cause:
  cluster too small for Defender overhead).
- ADR 0012 — Azure Disk PVC (Defender blocks Files shared-key auth).
