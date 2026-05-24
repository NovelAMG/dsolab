# Defender Helm Chart Artifacts

This directory holds the **rendered Kubernetes manifest** for the Microsoft Defender for Containers Helm chart, copied from `aks-cnapp-lab` and rewritten for `aks-dsolab-sea`. See ADR-0020 for the full story.

## Why this exists

Defender for Cloud's `Containers` plan toggle deploys the basic add-on
(2-container collector DaemonSet, no anti-malware). The **3rd container**
`microsoft-defender-antimalware-collector` only ships via the
`microsoft-defender-for-containers` Helm chart, which is **not** publicly
indexed in MCR (we tried multiple OCI paths — all 404).

On `aks-cnapp-lab` someone installed the chart manually during the CNAPP
demo onboarding. On `aks-dsolab-sea` it was never installed. To match the
detection + blocking capability we extracted the chart's rendered manifest
from cnapp-lab's Helm release secret and replayed it on our cluster.

## Files

- `defender-helm-manifest.yaml` — full rendered manifest (8 ClusterRoleBindings, 4 CRDs, 2 DaemonSets, 3 Deployments, 1 ValidatingWebhookConfiguration, plus RBAC), cluster-identity rewritten from `aks-cnapp-lab`/`rg-cnapp-lab` to `aks-dsolab-sea`/`rg-dsolab-sea`.
- `../scripts/defender/extract_helm_chart.py` — helper that decodes a `sh.helm.release.v1.*` secret and dumps the embedded chart files (used during investigation; not needed for routine apply).

## Apply

```bash
kubectl create namespace mdc --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n mdc -f k8s/mdc/defender-helm-manifest.yaml
```

The `-n mdc` flag is **important** — some resources in the manifest don't have an explicit `metadata.namespace`. Without `-n mdc` they'll land in `default` (we hit this in initial investigation; cleanup required).

After ~60 s, verify:

```bash
kubectl -n mdc get pods
# Expect: microsoft-defender-collectors-ds (3/3) on each node,
#         microsoft-defender-publisher-ds, *-pod-collector-misc,
#         *-pod-collector-virtual-kubelet, defender-admission-controller (1/1)

kubectl -n mdc get pod -l app.kubernetes.io/name=defender-k8s-sensor -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}' | grep antimalware
# Expect: microsoft-defender-antimalware-collector
```

## Caveats

- The manifest is a **point-in-time snapshot** (chart `0.10.5`,
  sensor chart `0.10.36`, anti-malware-collector image `1.0.16`, etc.). When
  Microsoft publishes a new chart on cnapp-lab via auto-provisioning, we
  may want to re-extract and re-apply.
- We do **not** install this via real Helm on dsolab — it's just
  `kubectl apply`. No `helm list` tracking. Acceptable for the lab.
- `failurePolicy: Ignore` on the webhook means if the admission controller
  is down, requests pass through. Per-policy `action: Block` (Antimalware,
  Binary Drift) is enforced when the controller is alive.
- The cnapp-lab admission controller had been crash-looping for 4+ days
  (cert-rotator stuck after initial install). Fix is a single
  `kubectl rollout restart deploy/defender-admission-controller -n mdc`.
  Same risk applies to our cluster on long-running pods.
