# ADR 0021: Phase 3.7 Image Integrity — scaffolded but not yet enforcing (pause point)

- **Status**: In progress (scaffolded; enforcement pending next session)
- **Date**: 2026-05-24
- **Phase**: 3.7

## Context

Phase 3.7 (per ADR-0016) is **Defender Image Integrity** — the admission
policy that rejects unsigned images, with our cosign keyless OIDC
identity `repo:NovelAMG/dsolab:ref:refs/heads/main` as the allowed
signer (the signing pipeline was built in Phase 3.6 / ADR-0017).

The Microsoft-managed Image Integrity feature is currently in
**preview** (`Microsoft.ContainerService/EnableImageIntegrityPreview`).
The path to enable it is three discrete things:

1. **Cluster-level**: `az aks update --enable-image-integrity` — installs
   Ratify into `gatekeeper-system` as a Gatekeeper external data
   provider and registers the Ratify CRDs.
2. **Tenant-level**: assign the Azure Policy initiative
   *"Deploy Image Integrity Workload Protection"* (or "Audit") to the
   subscription/RG/cluster. This creates the Gatekeeper
   `ConstraintTemplate` + `Constraint` that actually calls Ratify on
   every Pod admission.
3. **Cluster-level CRs**: author Ratify `Verifier` (cosign keyless
   issuer + subject regex) and `Store` (Azure ACR auth) so Ratify knows
   how to fetch + verify signatures against the right registry.

### Where we paused

We completed step 1 today:

- `Microsoft.ContainerService/EnableImageIntegrityPreview` **Registered**
- `az extension add -n aks-preview --version 19.0.0b1` (the latest
  `21.0.0b1` is incompatible with our azure-cli `2.78.0` —
  `ValueError: too many values to unpack` in `get_acns_enablement`)
- `az aks update -n aks-dsolab-sea -g rg-dsolab-sea --enable-image-integrity` succeeded
- `securityProfile.imageIntegrity.enabled = true` confirmed in `az aks show`
- `gatekeeper-system/ratify-*` Pod 1/1 Running
- 9 Ratify CRDs installed (`verifiers.config.ratify.deislabs.io`,
  `stores.config.ratify.deislabs.io`, `policies...`, `namespaced*`,
  `keymanagementproviders...`, `certificatestores...`)
- Default `policies.config.ratify.deislabs.io/ratify-policy` CR present
  (effectively a no-op until a Verifier+Store exist + Gatekeeper Constraint binds)

Steps 2 and 3 remain. Cluster is **not yet enforcing** signature
verification — `kubectl run nginx --image=nginx` still succeeds.

### Why Ratify (not a Microsoft proprietary engine)

Ratify is **CNCF Sandbox** (`deislabs.io` org), open source, primary
maintainer is Microsoft. AKS's `--enable-image-integrity` ships
**Microsoft-managed Ratify** — patched + upgraded + supported as part of
the AKS service. Same OSS engine you could `helm install` yourself, but
Microsoft owns the lifecycle.

ADR-0016 chose this managed path over "raw Ratify install ourselves" so
we don't take on patching / upgrade ownership for a security-critical
admission controller.

## Decision

Pause Phase 3.7 here. The cluster has Image Integrity **scaffolded but
not enforcing**, which is a valid intermediate state — Ratify is on, but
without a Verifier + Constraint it doesn't reject anything (default
behaviour is `allow`).

Next-session todo (in priority order):

1. Assign Azure Policy `Defender ImageIntegrity Workload Protection`
   initiative to RG `rg-dsolab-sea` (or just to AKS resource). The
   initiative parameter takes a regex of allowed Verifier subjects;
   set it to `repo:NovelAMG/dsolab:ref:refs/heads/main`.
2. Apply Ratify `Store` CR for `acrdsolabxsqb.azurecr.io` using AKS
   kubelet identity for AAD auth (or our existing `mi-gha-dsolab`
   workload identity).
3. Apply Ratify `Verifier` CR for **cosign keyless** with:
   - `certificateIdentityRegExp: "https://github.com/NovelAMG/dsolab/\\.github/workflows/build-spa\\.yml.*"`
   - `certificateOIDCIssuer: "https://token.actions.githubusercontent.com"`
4. Negative test: `kubectl run nginx --image=nginx -n n8n` → REJECTED.
5. Positive test: redeploy our SPA `acrdsolabxsqb.azurecr.io/dsolab/spa:a050341`
   (signed by Phase 3.6 / ADR-0017 pipeline) → ADMITTED.
6. Commit the Verifier+Store YAML + ADR-0022 close-out.

### Why pause instead of pushing through

Today the session has shipped:

- ADR-0018 (AKS B4als_v2 + MCAPSGov stop-gap) — PR #36 merged
- ADR-0019 (binary drift block via readOnlyRootFilesystem) — PR #38 merged
- ADR-0020 (Defender Helm chart replicated from cnapp-lab + cnapp crash
  fix) — PR #39 open
- And the Image Integrity scaffolding above

Steps 2 and 3 need fresh attention: the Ratify Verifier/Store YAML has
a non-trivial schema and any mistakes (wrong issuer URL, wrong subject
regex, ACR auth not working) result in the Constraint either letting
everything through or blocking everything including our own SPA. That
testing cycle is best done with a clear head, not at the end of a
six-PR day.

## Verification of current state

```bash
# Feature is on
az aks show -n aks-dsolab-sea -g rg-dsolab-sea \
  --query "securityProfile.imageIntegrity.enabled" -o tsv
# Expect: True

# Ratify pod is up
kubectl -n gatekeeper-system get pod -l app=ratify
# Expect: ratify-... 1/1 Running

# Ratify CRDs are installed
kubectl get crd | grep ratify.deislabs.io | wc -l
# Expect: 9

# Default ratify-policy exists but is a no-op until a Verifier exists
kubectl get policies.config.ratify.deislabs.io
# Expect: ratify-policy

# No verifier yet — nothing is actually blocked
kubectl get verifiers.config.ratify.deislabs.io
kubectl get namespacedverifiers.config.ratify.deislabs.io -A
# Expect: No resources found

# Proof that enforcement isn't active yet (smoke test before next session)
kubectl create ns ii-smoke
kubectl -n ii-smoke run x --image=nginx --restart=Never --rm -i -- echo unsigned image admitted
# Expect: succeeds (will be REJECTED after step 1+2+3 next session)
kubectl delete ns ii-smoke
```

## Caveats and gotchas for next session

1. **`aks-preview` version pinning matters.** We had to downgrade from
   `21.0.0b1` (latest) to `19.0.0b1` because the latest is incompatible
   with `azure-cli 2.78.0`. The first attempt also left a stuck
   "Updating" cluster operation for ~15 min before the second attempt
   could succeed. If anyone else hits the unpack error, pin the
   extension version.
2. **Azure Policy assignment scope choice.** The initiative can be
   assigned at subscription, RG, or AKS resource scope. Recommend AKS
   resource scope (`/subscriptions/.../managedClusters/aks-dsolab-sea`)
   so it doesn't accidentally apply to cnapp-lab and break their
   workflows.
3. **`failurePolicy` on the Gatekeeper webhook.** Default is `Ignore`
   for "Audit" mode and `Fail` for "Deny" mode. Pick the right one when
   assigning the initiative — `Audit` for first run, then `Deny` once
   the positive test passes.
4. **First-deploy chicken-and-egg.** Once enforcement is on, anything
   in `n8n` namespace that isn't signed will fail to schedule. Our SPA
   is signed; n8n upstream image (`docker.n8n.io/n8nio/n8n:1.69.0`) is
   **not** cosign-signed. Either exclude `docker.n8n.io` from the
   policy or restrict the Constraint scope to only images from our ACR.
5. **Ratify upgrades follow `--enable-image-integrity`.** Don't `helm
   install` your own Ratify on the side — Microsoft's reconciler will
   undo it (or worse, both will fight).
6. **Cosign keyless verification needs network egress.** Ratify needs
   to reach `https://rekor.sigstore.dev` and
   `https://fulcio.sigstore.dev` to verify the keyless transparency-log
   entry. Our cluster has public egress today; will need to allowlist
   these if we ever move to a private cluster (Phase 3.9 candidate).

## Related

- ADR-0016 — Defender Image Integrity over raw Ratify (the original
  choice this ADR is executing on)
- ADR-0017 — SPA build in CI not laptop (the signing pipeline; our
  signed images are what step 5 above verifies against)
- ADR-0019 — Binary drift block via readOnlyRootFilesystem (defence in
  depth: drift blocks attacker writes, image integrity blocks
  attacker-published images getting in in the first place)
- ADR-0020 — Defender Helm chart replicated from cnapp-lab (we
  discovered today that the MDC chart's `SecurityArtifactPolicy` CRD
  has **no** `signedArtifactGatedDeployment` field — signature checking
  is *not* something that chart does. Hence the Image Integrity / Ratify
  separate addon. This ADR documents why both exist.)
- Repo memory `/memories/repo/mcapsgov-auto-disable.md`
