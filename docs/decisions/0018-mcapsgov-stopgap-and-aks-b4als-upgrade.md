# ADR 0018: Azure-side stop-gap for MCAPSGov auto-disable + AKS B4als_v2 upgrade

- **Status**: Accepted
- **Date**: 2026-05-24
- **Phase**: 3 — between 3.6 (cosign signing) and 3.7 (Image Integrity)

## Context

Two related issues surfaced during the `tonzking123/dsolab → NovelAMG/dsolab`
org migration in PR #35:

### Issue 1 — `publicNetworkAccess: Disabled` on Storage + KV breaks CI

The TF Plan step on PR #35 failed because both the Terraform state storage
account (`stdsolabtfstate1db4`) and Key Vault (`kv-dsolab-sea-xsqb`) had
`publicNetworkAccess: Disabled`. CI runners on hosted GHA cannot reach
those endpoints. We re-enabled them by hand to unblock the merge.

Activity-log forensics on both resources show the same caller pattern at
~17:37 UTC every day:

```
Caller   : 7355f99c-0211-455d-aa02-4a559687ae60   (objectId in our tenant)
AppId    : eadea216-1d5c-4a4b-beaf-4f145e6b1cb4   (MCAPSGov-AutomationApp)
AppOwner : 72f988bf-86f1-41af-91ab-2d7cd011db47   (Microsoft corp tenant)
Method   : PATCH
Result   : Succeeded
```

`MCAPSGov-AutomationApp` is the **Microsoft corporate FDPO governance**
service principal (`https://aka.ms/fdpowiki`) that runs daily across all
subscriptions under the corp management group hierarchy. Our tenant
(`b676efda-…`, `novelguardamg.onmicrosoft.com`) lives under that hierarchy.

Crucially the flip is done by **direct ARM PATCH**, not through Azure Policy:
- Of the 6 MG-level assignments, only `MCAPSGovDeployPolicies` has a
  Modify-effect identity, and its only `publicNetworkAccess` policy targets
  `AIFoundryHub_PublicNetwork_Modify` — not Storage or Key Vault.
- Therefore `az policy exemption` would have no effect: MCAPSGov is not
  going through Azure Policy for these PATCHes.

### Issue 2 — Anti-malware needs more node RAM

Phase 3.7+ planned work needs a Defender sensor daemonset, an anti-malware
daemonset (Helm), and an Image Integrity admission webhook in
`gatekeeper-system`. On `3 × Standard_B2s` (2 vCPU / 4 GiB) the cluster
baseline is already at ~94% memory commitment (see ADR-0013); adding
~1.5 GiB of extra DaemonSet load per node would push us past schedulable
capacity.

## Decision

Two changes, shipped together:

### 1. Azure-native stop-gap CronJob in cluster (not a GHA workflow)

A `CronJob` in a new `lab-ops` namespace runs daily at **18:05 UTC**
(28 min after the MCAPSGov sweep) and re-enables `publicNetworkAccess` on
the two resources. The job:

- Uses a dedicated user-assigned MI `mi-lab-unflip` with `Contributor`
  scoped to **only** the two target resources (not the RG).
- Federates to `system:serviceaccount:lab-ops:lab-unflip` via AKS
  workload identity (issuer already on, ADR-trivial).
- Runs `mcr.microsoft.com/azure-cli:2.69.0` with `readOnlyRootFilesystem`,
  `runAsNonRoot`, dropped capabilities, and `emptyDir` for `/tmp`.

We chose AKS CronJob over the alternatives:

| Option | Why not |
|---|---|
| **GHA cron workflow** | The user explicitly asked for an Azure-side fix; also a GHA cron at 18:05 UTC is one more thing that could silently fail on org transfers / billing. |
| **Logic App Consumption** | Clean, but another resource to provision and explain; uses MS-managed compute that is itself in scope for MCAPSGov but its Storage is hidden. |
| **Azure Automation runbook** | Heaviest setup (modules, schedules, runbook editor) for the smallest job. |
| **Azure Policy exemption** | Doesn't apply — MCAPSGov flips outside of Azure Policy (see Context). |
| **FDPO formal exemption via aka.ms/fdpowiki** | The right long-term path but requires internal MS process; not viable for this trial timeline. |

This is **explicitly a stop-gap**. The permanent fix is Phase 3.9 (private
endpoints + self-hosted GHA runner in the VNet) — once everything that
talks to KV/Storage is on the private side, MCAPSGov flipping
`publicNetworkAccess` becomes a no-op for our pipelines.

### 2. Upgrade AKS system pool from `Standard_B2s` → `Standard_B4als_v2`

Doubles vCPU (2 → 4) and RAM (4 GiB → 8 GiB) per node on AMD-burstable
silicon. Cost moves from ~$82/mo to ~$132/mo (+$50/mo). Headroom analysis:

| Workload (3-node total) | Mem est. |
|---|---|
| `ama-logs`, `cilium`, `azure-cns`, `azure-policy`, CSI, cloud-node-mgr | ~2.5 GiB |
| Defender sensor (re-enabled in Phase 3.3, regressed; coming back) | ~0.9 GiB |
| Anti-malware DaemonSet (Phase 3.8 Helm) | ~1.8 GiB |
| Image Integrity / Ratify (Phase 3.7) | ~0.4 GiB |
| n8n + oauth2-proxy + SPA + unflip CronJob | ~0.8 GiB |
| **Sum** | **~6.4 GiB** |
| Cluster total on 3× B4als_v2 | **24 GiB** |

That leaves ~17 GiB of slack for n8n workflow execution and bursts — vs
~3 GiB on B2s today, half of which is already committed.

The change is implemented in-place via
`default_node_pool.temporary_name_for_rotation = "systmp"`, which under
AzureRM ~> 4.0 makes AKS:

1. Create a parallel pool `systmp` on the new SKU.
2. Cordon + drain the old `system` pool.
3. Reschedule all pods onto `systmp`.
4. Delete the old pool.
5. Rename `systmp` back to `system`.

No cluster recreation. Expect ~5–10 min unavailability per node during
drain; n8n state is in Postgres, oauth2-proxy is stateless, the SPA is
static — only chat sessions in-flight during drain will see a blip.

## Alternatives considered

1. **Standard_D2as_v5** (dedicated 2 vCPU / 8 GiB AMD) — would be safer
   for sustained anti-malware scans (no burst-credit exhaustion), but
   costs ~$186/mo vs $132. Burstable is fine for lab scan cadence (hourly
   or daily, not continuous).
2. **Standard_B4ms** (4 vCPU / 16 GiB Intel burstable) — 2× the RAM but
   ~$307/mo. Overkill for a 3-node lab.
3. **Standard_D4as_v5** (4 vCPU / 16 GiB dedicated) — production-grade
   choice at ~$372/mo. Earmarked for when this stops being a lab.
4. **Add a separate user node pool, keep system on B2s** — cleaner pattern,
   but doubles node count and lab complexity for marginal benefit at this
   scale.
5. **Use a GHA cron instead of in-cluster CronJob** for the unflip job —
   user prefers Azure-side; also GHA crons are best-effort SLA and missed
   runs during repo migrations are exactly when MCAPSGov damage hurts.

## Cost impact

- **Compute**: $82 → $132/mo (+$50/mo, +61% on AKS)
- **MI + role assignments**: $0
- **CronJob image pulls**: ~free (cached on node, 1 run/day, small image)
- **Total lab budget**: still under $200/mo target

## Consequences

**Positive:**

- Storage + KV stay reachable from CI without manual intervention.
- Cluster has headroom for the full Phase 3.7 / 3.8 stack.
- AMD burstable is genuinely cost-efficient for this workload mix.

**Negative:**

- One more in-cluster cronjob to monitor (`lab-ops/unflip-public-access`).
- MI sprawl: now `mi-gha-dsolab` + `mi-n8n-aoai-dsolab` + `mi-lab-unflip`.
- The first `tf-apply` after merge takes ~15–20 min (pool rotation).
- ACR, AOAI, Postgres may still get flipped by MCAPSGov on other days; the
  CronJob currently only unflips Storage + KV. We'll extend it lazily as
  the next victim appears, or accept and skip to Phase 3.9 private
  endpoints when the pattern is too noisy.

## Verification

After `tf-apply` completes:

```bash
# Nodes on the new SKU
kubectl get nodes -o wide
az aks nodepool show -g rg-dsolab-sea --cluster-name aks-dsolab-sea -n system \
  --query "{vmSize:vmSize, count:count}"
# Expect: Standard_B4als_v2, 3

# CronJob scheduled
kubectl -n lab-ops get cronjob
# Expect: unflip-public-access, "5 18 * * *", SUSPEND=False

# Manual smoke (anytime)
kubectl -n lab-ops create job --from=cronjob/unflip-public-access smoke-$(date +%s)
kubectl -n lab-ops logs job/smoke-<id>
# Expect: "[unflip] done." with both resources reporting Pna=Enabled

# Chat still works
curl -ksI https://chat.20.195.16.7.nip.io/ | head -1
# Expect: HTTP/2 302
```

## Related

- ADR-0001 — Defender sensor deferred to Phase 3 (and re-regressed since)
- ADR-0013 — Scale AKS to 3 nodes (this ADR replaces the B2s sizing)
- ADR-0015 — Phase 2 supply-chain gates (the CI we're trying to keep working)
- ADR-0016 — Defender Image Integrity over Ratify (the next phase this unblocks)
- Repo memory: `/memories/repo/mcapsgov-auto-disable.md`
