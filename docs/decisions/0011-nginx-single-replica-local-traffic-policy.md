# ADR 0011: NGINX Ingress single-replica + `externalTrafficPolicy: Local` on B2s nodes

- **Status**: Accepted
- **Date**: 2026-05-23
- **Phase**: 1E-a (post-mortem from first install attempt)

## Context

Phase 1E-a installs NGINX Ingress Controller on our lab AKS cluster. The cluster
runs 2 × `Standard_B2s` nodes (2 vCPU, 4 GB RAM each, ~$30/mo per node).
We originally configured the Helm chart with `controller.replicaCount=2` thinking
"cheap HA across the two nodes". Default service `externalTrafficPolicy` was left
at `Cluster` (the Kubernetes default).

## Problem we hit

The first `./scripts/03-cluster-prereqs.sh` run failed:

```text
Error: resource not ready, name: ingress-nginx-controller, kind: Deployment,
       status: InProgress
context deadline exceeded
```

Investigation showed:

1. **One pod healthy**, on `vmss000003`. Took 12 s to pull image, came up clean.
2. **Second pod stuck** on `vmss000002`:
   - Image pull took **6 min 56 sec** (vs. 12 s on the other node).
   - `FailedMount: timed out waiting for the condition` on the kube-api-access projected volume.
   - Liveness + readiness probes timed out (`context deadline exceeded`).
   - `kubectl top` showed `vmss000003` at **85 % memory**; `vmss000002` reported `<unknown>` (metrics-server couldn't reach kubelet).
3. After scaling to 1 replica, the public IP `20.195.16.7` was provisioned but `curl http://<ip>/` returned `HTTP 000` (connection timeout) on every attempt.
   - Root cause: `externalTrafficPolicy: Cluster` makes Azure LB round-robin to **all** nodes' nodePorts; kube-proxy/Cilium on each node then routes to the actual pod. When `vmss000002`'s networking was degraded, ~50 % of inbound packets blackholed there.

The cluster is also carrying uninvited workloads that AKS / Defender / Policy
add-ons keep re-injecting (see ADRs 0001, 0010):

- `gatekeeper-system` (Azure Policy add-on — keeps coming back even though
  Terraform sets `azure_policy_enabled = false`)
- `kube-system/defender-admission-controller`
- `kube-system/ama-logs` (Container Insights — we want this)

Combined with the AKS-mandatory daemonsets (`cilium`, `csi-azuredisk-node`,
`csi-azurefile-node`, `cloud-node-manager`, `azure-cns`, `azure-ip-masq-agent`)
and the system pods on the only available node pool, **a 2 × B2s cluster cannot
host 2 NGINX controller replicas without one becoming unscheduleable-in-practice**.

## Decision

Two changes to `scripts/03-cluster-prereqs.sh`:

1. **`controller.replicaCount = 1`** — single NGINX replica.
   Loses HA, but on a 2-node B2s lab cluster the HA was illusory anyway:
   one degraded node = no traffic if traffic policy is `Local`, half traffic
   blackholed if `Cluster`.

2. **`controller.service.externalTrafficPolicy = Local`** — Azure LB only routes
   to nodes where a NGINX pod exists.
   Preserves source IP (nice side-effect) and makes the LB health probe
   automatically remove unhealthy nodes from rotation.

Helm `--timeout` raised from `5m` to `8m` to absorb worst-case image pull on
degraded nodes.

## Alternatives considered

1. **Upgrade nodes to B4ms (4 vCPU / 16 GB).**
   2× the cost (~$120/mo just for nodes). Rejected for now; will revisit if
   Phase 1E-b's n8n + Postgres + oauth2-proxy push utilization too high. The
   B2s sizing was deliberately chosen as ADR-tagged lab spec.

2. **Restart `vmss000002` manually each time it degrades.**
   Treats the symptom, not the root cause. Same problem will recur after every
   add-on push from Defender / Policy.

3. **Add taints/tolerations to keep system pods off NGINX nodes.**
   Requires a second nodepool (more cost) and AKS Policy/Defender pods do not
   respect arbitrary taints. Rejected.

4. **`externalTrafficPolicy: Local` without reducing replicas.**
   Doesn't help — the second pod still can't come up due to node pressure.
   Must do both.

## Consequences

**Positive:**

- `./scripts/03-cluster-prereqs.sh` now succeeds first-try on a fresh cluster.
- `curl http://<public-ip>/` returns `HTTP 404` in <100 ms (NGINX default backend
  — the expected "ingress reachable" signal).
- Source IP preservation is now a side benefit (good for any future ip-based
  rate limiting in Phase 4).

**Negative:**

- No NGINX HA. If the single replica's node dies, ingress is down until the
  Deployment reschedules onto the other node (~60–90 s).
- For a lab demoing security, this is acceptable. **Phase 4 (production
  hardening) must revisit**: either add a `user` nodepool for workloads or
  upgrade base SKU.

## Verification

After the script (or a manual re-install):

```bash
kubectl get deployment -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.replicas}{"\n"}'
# Expect: 1

kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'
# Expect: Local

PUBLIC_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" "http://$PUBLIC_IP/"
# Expect: HTTP 404 in <0.5s
```

## Related

- ADR 0001 — Defender sensor deferred; CSPM still re-injects Gatekeeper/admission
  controllers which contribute to node pressure.
- ADR 0010 — Storage Blob role at SA scope (also discovered via failure-first
  debugging during this phase).
- Future: when adding a `user` nodepool in Phase 4, revisit single-replica
  decision and consider PodDisruptionBudget.
