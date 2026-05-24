# ADR 0020: Replicate Defender Helm chart from cnapp-lab to dsolab for anti-malware + drift detection

- **Status**: Accepted
- **Date**: 2026-05-24
- **Phase**: 3.8 (anti-malware) — between drift-block (ADR-0019) and Image Integrity (ADR-0016 / Phase 3.7)

## Context

By the end of ADR-0019 we had **binary drift BLOCKING** at the workload level
(readOnlyRootFilesystem on n8n / oauth2-proxy / spa). What we did not have was
**drift DETECTION** — the Defender alert *"A drift binary detected executing
in the container"* never fired for `aks-dsolab-sea` even after we ran a
canonical attack chain (apk add + curl + chmod + exec a downloaded binary).

A second cluster on the same subscription (`aks-cnapp-lab`) was producing
those alerts. Investigation revealed:

```
                  aks-dsolab-sea           aks-cnapp-lab
add-on (toggled)  ✓ securityMonitoring=on  ✓ securityMonitoring=on
kube-system DS    ✓ collector + publisher  ✓ collector + publisher
                    (2-container DS,         (2-container DS, same)
                    no anti-malware)
mdc namespace     ✗ empty                  ✓ defender-k8s Helm release v0.10.5
mdc/collectors-ds ✗ does not exist         ✓ 3 containers including
                                             microsoft-defender-antimalware-collector:1.0.16
mdc/defender-     ✗ does not exist         ✓ but 0/1 CrashLoopBackOff for 4d12h
  admission-                                 (cert-rotator stuck)
  controller
```

Two distinct facts:

1. **The "Containers" Defender plan toggle** at subscription level only
   triggers the Azure Policy DIE assignments that install the **add-on**
   (kube-system 2-container DS). It does **not** install the
   `microsoft-defender-for-containers` Helm chart in `mdc`. The chart on
   cnapp-lab was installed by hand during the original CNAPP demo
   onboarding — the activity log shows no `runCommand` events around the
   install time and no `Microsoft.KubernetesConfiguration` extension was
   registered.

2. The chart isn't pullable from MCR. We tried five OCI paths
   (`oci://mcr.microsoft.com/azuredefender/{stable,k8s/stable,charts}/...`
   etc.) — all return 404. Microsoft pushes it to selected clusters via a
   backend mechanism that's not user-callable.

## Decision

**Replicate the chart from cnapp-lab into dsolab by extracting the rendered
manifest and applying it directly with `kubectl`.**

Mechanics:

1. `helm get manifest defender-k8s -n mdc --kube-context cnapp-lab > defender-manifest.yaml`
2. `sed 's|cnapp-lab|dsolab-sea|g; s|rg-cnapp-lab|rg-dsolab-sea|g' defender-manifest.yaml > defender-manifest-dsolab.yaml`
3. `kubectl create namespace mdc && kubectl apply -n mdc -f k8s/mdc/defender-helm-manifest.yaml`

After ~60 s of image pulls, three things are true on dsolab:

- `microsoft-defender-collectors-ds` is **3 containers** (the third being
  `mcr.microsoft.com/azuredefender/stable/anti-malware-collector:1.0.16` —
  matches cnapp-lab exactly).
- `mdc-antimalware-policy` AntimalwarePolicy CR is in place with both
  `workloadRule.action: Block` and `hostRule.action: Block` (came along
  with the manifest).
- `defender-admission-controller` Deployment is 1/1 Running (after we
  also corrected for the SA initially being placed in `default` namespace
  due to my missing `-n mdc`).

We re-ran the drift attack and:

- The same EXEC of a freshly downloaded binary now fires the *"A drift
  binary detected executing in the container"* alert (same alert that
  appears on cnapp-lab).
- Subsequent `wget` calls of binaries inside `drift-test/drift-victim`
  end up as **0-byte files** with `wget` getting `SIGKILL` (exit 137) —
  the anti-malware collector is actively quarantining writes.

So both detection AND in-pod runtime block are working.

### Also fixed: cnapp-lab admission controller crash loop

cnapp-lab's `defender-admission-controller` had been `0/1
CrashLoopBackOff` for 4 d 12 h (917 restarts) with the logs showing:

```
"failed to wait for cert-rotator caches to sync kind source: *v1.Secret:
timed out waiting for cache to be synced for Kind *v1.Secret"
"failed to wait for securityartifactpolicy caches to sync"
```

Both clusters have **identical** images, RBAC, CRD versions, and cert
secrets. A simple `kubectl rollout restart deploy/defender-admission-controller -n mdc`
on cnapp-lab brought up a healthy 1/1 pod. The original pod was just
stuck in a permanent bad state from its install on 2026-05-16.

This means cnapp-lab's drift **blocking** (admission-controller path) had
been a no-op for 4 days despite the policy saying `action: Block`. With
`failurePolicy: Ignore` on the webhook, every admission decision while
the controller was down silently passed through.

## Alternatives considered

1. **Wait for Defender for Cloud to auto-provision the chart on
   `aks-dsolab-sea` after the OAuth re-auth.** We do see partial signals
   (the CRDs and `mdc-vulnerability-assessment-policy` CR were
   pre-existing on dsolab when we started, suggesting some
   auto-provisioning began at some earlier point), but the workloads
   never came. Open-ended wait was not acceptable.
2. **Install Sigstore policy-controller as a substitute.** Different
   product — handles cosign verification only, not anti-malware. Useful
   for Image Integrity (Phase 3.7) but not a replacement for the Defender
   sensor we wanted to compare with cnapp-lab.
3. **Use the public `microsoft.azuredefender.kubernetes` k8s-extension
   (preview).** Returns `InvalidResourceType` against
   `Microsoft.KubernetesConfiguration` for the API version we have; the
   preview is not consistently available in southeastasia.
4. **Stay with the add-on only and skip anti-malware.** Acceptable per
   ADR-0019 since drift is blocked at the FS layer anyway, but loses the
   alert signal that flows into Defender for Cloud's incident pipeline.
   Hand-extracting a working chart from cnapp-lab gives us both layers
   with one apply.

## Cost impact

- **Compute**: chart adds ~1 GiB memory per node. Pre-Helm node memory
  was ~38–41 %, post-Helm ~56–66 % on our 3 × B4als_v2 nodes. No new
  Azure resources, no extra billing line items (the sensor is part of
  Defender for Containers, billed per pricing plan we already pay for).
- **Engineering**: ~2 hours of investigation + apply + validation. Not
  repeating on every cluster — once Microsoft auto-provisioning catches
  up, we can compare versions and either keep or remove our hand-applied
  copy. Documented so the swap is mechanical.

## Consequences

**Positive:**

- Drift binary alerts now flow into Defender for Cloud from dsolab — same
  signal cnapp-lab produces.
- In-pod runtime block (0-byte truncation of dropped binaries) layered on
  top of the FS-level block from ADR-0019.
- Discovered + fixed the cnapp-lab crash that had silently neutralised
  its admission-controller for 4 days. Same fix pattern is one
  `rollout restart` if dsolab ever goes the same way.

**Negative:**

- Hand-extracted manifest is a point-in-time copy of chart `0.10.5` /
  sensor `0.10.36`. We won't get Microsoft's chart updates automatically.
- We don't have a real Helm release on dsolab, so `helm upgrade` doesn't
  work — diffs need a fresh `helm get manifest` from cnapp-lab.
- The `mdc` namespace is now a *third* Defender footprint on dsolab
  alongside `kube-system` (add-on) and the AKS add-on's own
  `defender-admission-controller` (also in kube-system). Some duplication
  of work (both collectors-ds variants run process collection). Memory
  cost noted above.
- Per ADR-0019, drift attack at runtime is already prevented by
  `readOnlyRootFilesystem`. The anti-malware block is a second layer for
  defense-in-depth, not a strict requirement.

## Verification

```bash
# 1. Anti-malware container exists on every node
DS=$(kubectl -n mdc get pod -l app.kubernetes.io/name=defender-k8s-sensor -o name | head -1)
kubectl -n mdc get "$DS" -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}'
# Expect to include "microsoft-defender-antimalware-collector"

# 2. AntimalwarePolicy is in Block mode
kubectl get antimalwarepolicies.defender.microsoft.com mdc-antimalware-policy \
  -o jsonpath='{.spec.rules[*].workloadRule.action}'
# Expect: Block

# 3. Admission controller is 1/1 (the lethal silent-failure mode is
#    1/0 / CrashLoopBackOff — that's what bit cnapp-lab)
kubectl -n mdc get deploy defender-admission-controller \
  -o jsonpath='{.status.readyReplicas}/{.spec.replicas}'
# Expect: 1/1

# 4. Drift attack fires alert
#    (run in a throwaway namespace; ADR-0019 blocks already prevent this
#    in n8n)
kubectl create ns drift-test
kubectl -n drift-test run v --image=alpine:3.20 --restart=Never --command -- sleep 600
kubectl -n drift-test exec v -- sh -c 'wget -O /tmp/d https://github.com/krallin/tini/releases/download/v0.19.0/tini-static-amd64 && chmod +x /tmp/d && /tmp/d --version'
# Within 10–20 min: Defender alert "A drift binary detected executing in the container"
# /tmp/d ends up as 0 bytes; subsequent wget calls SIGKILL.
kubectl delete ns drift-test
```

## Related

- ADR-0016 — Defender Image Integrity over Ratify (Phase 3.7 followup;
  this ADR establishes that the chart we hand-extracted does **not**
  cover image signature verification — that's its own feature)
- ADR-0019 — Binary drift blocks via `readOnlyRootFilesystem` (ADR-0019
  is the FS-level block; ADR-0020 is the runtime detection + truncation
  layer on top)
- ADR-0018 — AKS B4als_v2 upgrade (the 16 → 24 GiB cluster RAM is what
  made the chart's ~1 GiB / node footprint acceptable)
- Repo memory: `/memories/repo/mcapsgov-auto-disable.md`
- Repo file: `k8s/mdc/README.md`
- Repo file: `scripts/defender/extract_helm_chart.py`
