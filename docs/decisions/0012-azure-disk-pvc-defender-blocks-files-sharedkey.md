# ADR 0012: Use Azure Disk for n8n PVC — Defender blocks Azure Files shared-key auth

- **Status**: Accepted
- **Date**: 2026-05-23
- **Phase**: 1E-b (discovered during first n8n deploy)
- **Supersedes**: implicit choice in PR #7's original PVC

## Context

Phase 1E-b's first PVC used the default `azurefile-csi` StorageClass (Azure
Files, ReadWriteMany). Rationale at the time: RWX makes pod rescheduling
across nodes cheap, and Azure Files is the AKS-default for "I want shared
storage without thinking about it".

The auto-provisioned Azure Files storage account (created in the AKS node
RG by the CSI driver) had its `allowSharedKeyAccess` flipped to `false`
within seconds of creation by Microsoft Defender for Cloud's CSPM
auto-remediation. The Azure Files CSI driver mounts SMB shares using the
storage account key, so the kubelet's `mount.cifs` immediately failed with:

```text
mount error(13): Permission denied
```

Manually re-enabling the flag with
`az storage account update --allow-shared-key-access true` was **rejected**
by the platform — the update returned `false`. This is not just
auto-remediation that we could outrun; an Azure Policy assignment
(`Storage accounts should prevent shared key access`) is in `deny` mode at
the subscription / management group level. Defender for Cloud's foundational
CSPM enables this policy by default.

Workarounds considered for sticking with Azure Files:

1. **Disable the policy assignment.** Out of scope — it's at MG scope and
   intentionally enforced as part of the broader Defender posture. Disabling
   it for one storage account is not granular.
2. **Use a customer-managed storage account with `allowSharedKeyAccess=true`
   via a `PersistentVolume` (not dynamic).** Possible but: same policy
   refuses to let us create the SA with shared keys enabled.
3. **Use Azure Files OAuth / NFS protocol.** OAuth mount is preview and
   requires extra RBAC plumbing on the kubelet identity; NFS requires the
   SA to be Premium FileStorage (~$200/mo minimum), way over our lab budget.

## Decision

Switch n8n's PVC to `managed-csi` (Azure Disk). Azure Disk's CSI driver
authenticates with Microsoft Entra (the AKS kubelet identity), so it is
unaffected by `allowSharedKeyAccess` policy.

Trade-off accepted: Azure Disk is `ReadWriteOnce` (single-node attach).
The n8n Deployment already uses `strategy: Recreate` per ADR 0011 (single
replica, no HA on B2s anyway), so the RWO constraint costs us nothing
practical.

## Consequences

**Positive:**

- n8n PVC mounts in <30s without manual intervention.
- No fight with Defender CSPM on this volume.
- Disk attach uses managed identity; one less credential lifecycle to think about.

**Negative:**

- If we ever want to horizontally scale n8n (enterprise queue mode), we
  need a different storage strategy for the binary data dir
  (`/home/node/.n8n`). Likely candidates: split binary data into ACR
  (workflows-as-OCI-artifacts) or revisit Azure Files with private
  endpoints + a customer-managed SA where we can negotiate policy
  exemption.
- Cluster-wide implication: **any future workload that wanted Azure Files
  dynamic provisioning hits the same wall.** Phase 4 should consider
  whether to negotiate an exemption from the policy, or standardize on
  Azure Disk for everything.

## Verification

```bash
# PVC bound on managed-csi
kubectl get pvc -n n8n n8n-data \
  -o jsonpath='{.spec.storageClassName} {.status.phase}{"\n"}'
# Expect: managed-csi Bound

# Pod has volume mounted
kubectl exec -n n8n deploy/n8n -- mount | grep /home/node/.n8n
# Expect: a /dev/sdX entry, not //*.file.core.windows.net
```

## Related

- ADR 0001 — Defender sensor deferred; this is another case of Defender
  CSPM-enforced policy that we have to design around at our layer.
- ADR 0011 — NGINX single-replica + Local traffic policy (same theme:
  small cluster + opinionated CSPM = workaround in workload manifests).
