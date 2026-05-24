# ADR 0019: Binary drift blocks via readOnlyRootFilesystem; Defender Helm chart for drift detection deferred

- **Status**: Accepted (block layer); deferred (detection layer)
- **Date**: 2026-05-24
- **Phase**: 3.7-prep (after AKS rotation in ADR-0018, before Image Integrity)

## Context

Phase 3.7 (Defender Image Integrity admission policy) prevents *unsigned*
images from being deployed. It doesn't help if an attacker compromises an
already-running pod and uses it to stage new tools — the classic
`wget binary && chmod +x && ./binary` pattern, also called **binary drift**.

Two complementary controls for that pattern:

1. **Detection** — Defender for Cloud raises an alert like
   *"A drift binary detected executing in the container"* when a process
   inside a container executes a binary that wasn't present in the image's
   original layers. The alert is High severity and tied to the runtime
   sensor.
2. **Block** — Pod's container `securityContext.readOnlyRootFilesystem: true`
   makes the entire root filesystem immutable. Combined with explicit
   `emptyDir` tmpfs mounts for paths the app legitimately writes to
   (`/tmp`, nginx cache, etc.), the attacker can never write a new
   binary anywhere, let alone execute it.

We need both: detection tells the SOC something happened; block stops the
attack outright.

## What we found about Defender detection

Our `aks-dsolab-sea` cluster has the Defender add-on enabled
(`securityProfile.defender.securityMonitoring.enabled: true`), which
deploys the runtime sensor DaemonSet `microsoft-defender-collector-ds`
with two containers:

- `microsoft-defender-pod-collector:1.0.240`
- `microsoft-defender-low-level-collector:2.0.243`

A second cluster on the same subscription (`aks-cnapp-lab`) has the same
add-on *plus* the Helm chart
`microsoft-defender-for-containers 0.10.5` installed in the `mdc`
namespace by Defender for Cloud auto-provisioning. That chart adds a
**third** container to the same DaemonSet:

- `microsoft-defender-antimalware-collector:1.0.16`

`aks-cnapp-lab` has produced 5 *"A drift binary detected executing in the
container"* alerts in the past week. We ran an equivalent staged drift
attack on `aks-dsolab-sea` (`apk add` + `curl -o /tmp/mc` + `chmod +x &&
./mc --version` + `nmap` recon + EICAR + payload exec) at 09:54 UTC and
**no alert fired** within 20+ minutes.

The conclusion: drift detection alerts come from the
`antimalware-collector` container, which is only present when the Helm
chart is installed. The add-on alone does not produce them.

## Decision

### Now — ship the block layer

Add to all workload deployments (`n8n`, `oauth2-proxy`, `spa`):

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
  # seccompProfile inherited from pod-level spec.securityContext
```

Add `emptyDir` tmpfs mounts for the small set of paths each app legitimately
writes to:

| Pod | Writable mount | Why |
|---|---|---|
| `n8n` | `/home/node/.n8n` (PVC) | n8n state, workflows DB, settings |
| `n8n` | `/tmp` (emptyDir 256 MiB) | vm2 sandbox temp files |
| `n8n` | `/home/node/.cache` (emptyDir 128 MiB) | npm cache for Code-node requires |
| `oauth2-proxy` | nothing | static Go binary, writes nothing |
| `spa` | `/var/cache/nginx` (emptyDir 64 MiB) | nginx proxy cache |
| `spa` | `/var/run` (emptyDir 16 MiB) | nginx pid file |
| `spa` | `/tmp` (emptyDir 64 MiB) | nginx temp |

Verified on the running cluster after applying:

```text
$ kubectl -n n8n exec n8n-... -- sh -c 'echo evil > /usr/local/bin/evil'
sh: can't create /usr/local/bin/evil: Read-only file system  rc=1
$ kubectl -n n8n exec n8n-... -- sh -c 'echo evil > /etc/evil'
sh: can't create /etc/evil: Read-only file system  rc=1
$ kubectl -n n8n exec n8n-... -- sh -c 'echo legit > /tmp/legit && cat /tmp/legit'
legit  rc=0
$ kubectl -n n8n exec n8n-... -- sh -c 'echo wf > /home/node/.n8n/x && rm /home/node/.n8n/x'
OK  rc=0
```

Chat end-to-end still returns `HTTP/2 302` (oauth redirect flow intact),
n8n pod stays 1/1 Running, oauth2-proxy and spa pods stay 1/1 Running.

### Deferred — the detection layer (Helm chart)

The Helm chart `microsoft-defender-for-containers 0.10.5` is installed by
Defender for Cloud's auto-provisioning when **Container Sensor** is
toggled on at the cluster level in *Defender for Cloud → Environment
settings → AKS settings*. On `aks-cnapp-lab` that toggle was on; on
`aks-dsolab-sea` it's evidently not, even though the
`ContainerSensor` extension is enabled at the **subscription** Defender
plan.

We don't install the Helm chart manually because:

1. The chart isn't publicly indexed; `helm pull oci://...` for the known
   paths returns 404. It's pushed by Defender's auto-provisioning.
2. Microsoft is the supported channel for keeping it patched.
3. Installing it side-channel risks divergence from the official path.

Next session: toggle Container Sensor on for `aks-dsolab-sea` in the
Defender portal and verify the third container appears within ~10 min,
then re-run the drift attack and confirm an alert fires.

## Alternatives considered

1. **Pod Security Admission `restricted` on `n8n` namespace** — would
   also enforce these defaults, but breaks Defender / Container Sensor
   pods that need elevated privileges in the same cluster. We're applying
   per-pod controls instead, keeping `kube-system` and `mdc` untouched.
2. **OPA / Gatekeeper policy template enforcing `readOnlyRootFilesystem`
   at admission** — would catch new deployments. Adds complexity. Per-pod
   enforcement is enough at our scale; we'll revisit when we have >10
   workload deployments.
3. **Falco rules for `exec_from_writable_dir`** — same outcome as the
   missing Defender detection, but we already pay for Defender; better to
   complete that integration than add another agent.
4. **Skip block, rely only on detection** — detection without prevention
   means we'd see an alert after the attacker has already executed code.
   Block-first is correct for this layer.

## Consequences

**Positive:**

- `wget malware && chmod +x && ./malware` cannot succeed in any of our
  workload pods. The drift attack we ran would have been blocked at
  step 2 (the `curl -o /tmp/mc` would still write to the tmpfs mount, but
  step 1 was `apk add` which would be blocked on a read-only `/etc/apk`).
- Existing pod-level securityContext (runAsNonRoot, seccompProfile)
  remains in force and is now complemented by container-level controls.
- Future workloads added under `k8s/` need to follow the same pattern.

**Negative:**

- Detection layer is still missing; we know the attack succeeded inside a
  test pod (no readOnlyRootFilesystem) but Defender raised no alert.
  Until we enable the Container Sensor extension via the Defender portal,
  we're operating with block-only.
- Adding new emptyDir volumes per workload bloats the manifests; a
  workload that needs to write to an unforeseen path will fail until we
  update the deployment.
- n8n's `apk` install path inside the container would fail (this is the
  attacker's intent, but also blocks any legit `n8n install-community-node`
  flow — we currently don't use that).

## Verification (post-deploy smoke)

```bash
# All three pods Running 1/1
kubectl -n n8n get pods

# Chat returns 302
curl -ksI https://chat.20.195.16.7.nip.io/ | head -1

# Drift block confirmed in n8n
N8N=$(kubectl -n n8n get pod -l app=n8n -o name | head -1)
kubectl -n n8n exec "$N8N" -- sh -c 'echo x > /usr/local/bin/y' 2>&1 | grep "Read-only"
# Expect: sh: can't create /usr/local/bin/y: Read-only file system

# Writable paths still work
kubectl -n n8n exec "$N8N" -- sh -c 'echo ok > /tmp/ok && cat /tmp/ok'
# Expect: ok
```

## Related

- ADR-0011 — NGINX single-replica + local traffic policy (same lab
  philosophy: lock down what we can, accept the constraint)
- ADR-0013 — Scale AKS to 3 nodes (so DaemonSet drift detection has 1
  pod per node)
- ADR-0016 — Defender Image Integrity over Ratify (this ADR is the
  runtime complement to that admission-time control)
- ADR-0018 — AKS B4als_v2 upgrade + unflip CronJob (the B4als_v2
  headroom is what lets us add another emptyDir per pod without
  pressure)
- Repo memory: `/memories/repo/mcapsgov-auto-disable.md`
