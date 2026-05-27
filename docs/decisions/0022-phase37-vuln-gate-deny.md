# ADR 0022: Phase 3.7 pivot — vulnerability-gated admission instead of cosign image signing

- **Status**: Accepted
- **Date**: 2026-05-25
- **Phase**: 3.7
- **Supersedes (in part)**: ADR-0016, ADR-0021

## Context

Per ADR-0016 we chose "Defender Image Integrity over raw Ratify" as the
Phase 3.7 admission-control mechanism — assume Microsoft-managed Ratify
verifying the cosign-keyless signatures we produce in CI (ADR-0017).
ADR-0021 paused the work after enabling the Image Integrity AKS feature
and getting Ratify running.

Resuming today, three things were discovered:

1. **AKS-managed Ratify is notation-only.** Its image is
   `mcr.microsoft.com/aks/notaryproject/ratify:v1.4.1`, and the
   ConfigMap `gatekeeper-system/ratify-configuration` explicitly lists
   only the `notation` plugin (artifactTypes
   `application/vnd.cncf.notary.signature`). The ConfigMap is reconciled
   by AKS (`kubernetes.azure.com/managedby: aks`) so editing it is
   futile. The Azure Policy initiative *"[Preview]: Use Image Integrity
   to ensure only trusted images are deployed"* maps to a single
   verification definition named **"Kubernetes clusters should only use
   images signed by notation"**, with `effect` enum `[Audit, Disabled]`
   only. There is no path through this initiative to verify cosign
   signatures or to deny.

2. **Microsoft does not offer image signing as a service.**
   `az acr --help | grep -i sign` returns 0 matches. The ACR `Tasks`
   primitive can run arbitrary build steps including signing, but
   there's no managed "press here to sign your images" feature. Signing
   is a producer-side activity. We sign with cosign keyless OIDC in
   `.github/workflows/build-spa.yml` (ADR-0017).

3. **The Defender admission controller (Helm chart from ADR-0020) has
   an admission gate we already deployed but didn't realise was
   admission control.** The `SecurityArtifactPolicy` CR
   `mdc-vulnerability-assessment-policy` was auto-created in
   `audit` mode and wired to a `ValidatingWebhookConfiguration`
   `defender-admission-controller.mdc.svc` that intercepts
   CREATE/UPDATE on Pods + Deployments + ReplicaSets + StatefulSets +
   DaemonSets + Jobs + CronJobs (excluding kube-system,
   gatekeeper-system, AKS-managed namespaces). Same admission-control
   mechanism as Image Integrity (validating webhook); different gating
   signal (MDVA scan results vs notation signature).

## Decision

**Pivot Phase 3.7 from cosign-signed-image admission to
vulnerability-gated admission.** Reasons:

- The vulnerability gate is **stronger security**: a signed image with
  critical CVEs is still dangerous. The vuln gate catches that; the
  signature gate does not.
- Engine is already deployed (`defender-admission-controller` from
  ADR-0020's chart replication).
- Works regardless of cosign-vs-notation choice — it's about CVE
  findings, not signature provenance.
- ADR-0016's intent (admission-time control via Microsoft-managed
  Defender) is preserved; the specific engine changes from Ratify to
  `defender-admission-controller`.

Phase 3.10 will revisit signed-image enforcement when notation signing
is added to CI (or when Microsoft's Ratify build gains a cosign plugin,
or when we install upstream Ratify with cosign).

### Configuration applied

`k8s/mdc/vuln-gate-policy.yaml` (overwrites the auto-created CR):

```yaml
spec:
  vulnerabilityAssessmentGatedDeployment:
    - name: dsolab-critical-cve-block
      action: deny                           # was: audit
      configuration:
        maxAllowedSeverities: { critical: 0 }
        blockUnscannedImages: false           # lab posture; flip true for hardening
        unsupportedRegistries:
          - mcr.microsoft.com                 # original defaults
          - docker.io
          - public.ecr.aws
          - gcr.io
          - jfrog.io
          - docker.n8n.io                     # added: n8n upstream
          - quay.io                           # added: cert-manager, oauth2-proxy
          - registry.k8s.io                   # added: ingress-nginx official
          - ghcr.io                           # added: future-proof
```

Without expanding `unsupportedRegistries`, flipping `audit → deny`
would have blocked cert-manager, oauth2-proxy, n8n, and ingress-nginx
at next pod recreation (MDVA can only scan ACR; everything else is
unscannable).

`k8s/spa/deployment.yaml` pinned to the cosign-signed digest
`sha256:b483faec83ee15675ad6bc7bc31be17f54e8afdfd68406b211791124d49bdfa4`
(the build `a050341` from ADR-0017's CI run) so the gate's verdict is
against a known, immutable artifact rather than a moving `:latest`.

### Chart RBAC bug discovered + fixed

The defender-admission-controller chart (ADR-0020) ships RBAC that
**omits** list/watch on its own `securityartifactpolicies.defender.microsoft.com`
CRD plus update on `validatingwebhookconfigurations.admissionregistration.k8s.io`.
Without these, the controller-runtime informer cache fails to sync and
the cert-rotator (open-policy-agent/cert-controller) cannot write the
CA bundle into the webhook config. Concrete symptoms:

- Continuous `cannot list resource securityartifactpolicies ... forbidden`
  log lines.
- "Still waiting for certificate rotator setup" loops every 30 s.
- Policy CR edits not picked up (`verify config action: audit` logged
  even after we patched the CR to `deny`).
- This is the same latent bug that left cnapp-lab's admission
  controller crash-looping for 4 d 12 h in ADR-0020.

Patched by `k8s/mdc/admission-rbac-patch.yaml`: a new ClusterRole
`defender-admission-controller-defender-crds-reader` that adds
list/watch on the four `defender.microsoft.com` policy CRDs plus
update/patch on `validatingwebhookconfigurations`, bound to the chart
SA. After applying and restarting the controller, `is forbidden`
errors dropped to zero in 2 min and cert-rotator finished its loop
(*"Updated current TLS certificate"*).

This patch is not strictly part of Phase 3.7 — it's bug-fixing the
chart we hand-applied in ADR-0020 — but it's a precondition for the
vuln gate to actually enforce. Documented here, not in a separate ADR,
because it surfaced as part of this work.

## Negative test (passed)

```text
$ kubectl patch securityartifactpolicies.defender.microsoft.com \
    mdc-vulnerability-assessment-policy --type=json \
    -p '[{"op":"replace","path":"/spec/.../blockUnscannedImages","value":true}]'
$ kubectl -n n8n run negtest \
    --image=acrdsolabxsqb.azurecr.io/dsolab/spa:be79d39 --restart=Never

Error from server: admission webhook
"defender-admission-controller.kube-system.svc" denied the request:
   No valid reports found on ratify response
   Unscanned images are not allowed by policy
   Verifier rule name: dsolab-critical-cve-block
```

`blockUnscannedImages` was reverted to `false` immediately after the
demo so the lab posture (gate on positive CVE findings only, don't
require every image to have a scan) is what's committed.

## Positive test (passed)

```text
$ kubectl -n n8n get pods
n8n-...           1/1 Running    # docker.n8n.io image, exempt registry
oauth2-proxy-...  1/1 Running    # quay.io image, exempt registry
spa-...           1/1 Running    # acrdsolabxsqb.azurecr.io scanned + clean

$ curl -ksI https://chat.20.195.16.7.nip.io/ | head -1
HTTP/2 302
```

All workload pods continue to schedule, chat OAuth flow returns 302.

## Alternatives considered

1. **Sign with notation alongside cosign** and use Microsoft's
   audit-mode Image Integrity policy. Deferred to Phase 3.10 — adds CI
   surface area; Microsoft's policy is audit-only anyway, so we'd still
   need the vuln gate for actual deny.
2. **Disable AKS-managed Image Integrity, install upstream Ratify with
   cosign plugin** + write our own Gatekeeper Constraint. Contradicts
   ADR-0016. Operating Ratify ourselves means we patch CVEs in it,
   which is moving the security boundary the wrong direction.
3. **Just configure the existing MDC admission-controller's
   `--require-signed-artifacts=true`** which is set in its args. No
   public CR exists to configure WHICH signatures are required and the
   flag is undocumented for our chart version. Doesn't appear to do
   anything observable when there's no SecurityArtifactPolicy with a
   `signedArtifactGatedDeployment` rule (which doesn't exist in the
   CRD).
4. **Skip Phase 3.7 entirely**, accept drift block (ADR-0019) +
   anti-malware (ADR-0020) as sufficient. Documented as a possibility
   in ADR-0021. Today's discovery that vuln-gate is "free" (engine
   already deployed; just CR action flip) made enforcement obviously
   worth doing.

## Consequences

**Positive:**

- Pods with critical CVEs from MDVA scans cannot deploy. Pods from
  registries Defender can't scan get auto-admitted (acceptable
  trade-off for a 3rd-party-heavy lab).
- Defender admission-controller is now fully functional — the cert
  rotator works, policy reconciliation works, audit/deny is
  enforceable. Same fix saves cnapp-lab too (the rollout-restart
  from ADR-0020 was a workaround; this is the actual cause + fix).
- We have **two complementary admission gates** running in parallel:
  Microsoft's audit-only `imageIntegrityNotationVerification` Azure
  Policy (Gatekeeper Constraint, audit) + our `dsolab-critical-cve-block`
  vuln rule (defender-admission-controller, deny). They don't conflict
  — different webhooks, different decision data.

**Negative:**

- Tag-pinned SPA only. New build pushes require `scripts/09-deploy-spa-and-workflow.sh`
  to update the digest in `k8s/spa/deployment.yaml`. Will commit that
  follow-up in the next session if not already handled.
- Lab keeps `blockUnscannedImages: false` to avoid breaking deploys of
  freshly-pushed images before MDVA finishes scanning. Production
  posture would be `true`.
- The chart RBAC fix is a forever-on bandaid against Microsoft's
  chart. If Microsoft ships a chart update we re-apply over it, the
  fix file needs to still be there. Documented in
  `k8s/mdc/admission-rbac-patch.yaml`.
- Ratify is now installed but unused. We could `--disable-image-integrity`
  to free its ~200 Mi node memory, but keeping it around for Phase
  3.10 is cheap.

## Phase 3.10 — deferred signed-image enforcement

Take one of these paths when we revisit:

1. Add `notation sign` step to `build-spa.yml` after the cosign step,
   using a signing identity tied to an Azure Key Vault key + AKV
   Notation plugin. Then assign the `imageIntegrityNotationVerification`
   policy and verify negative/positive tests on signed-vs-unsigned.
2. OR: `az aks update --disable-image-integrity` to free Ratify
   resources; `helm install ratify upstream` from
   `ghcr.io/ratify-project/...` with cosign plugin enabled; author
   ClusterImagePolicy CRs; write our own Gatekeeper Constraint
   pointing at Ratify as external data.

## Related

- ADR-0016 — Defender Image Integrity over raw Ratify (partially
  superseded — engine choice changed from Ratify→defender-admission-controller)
- ADR-0017 — SPA build in CI not laptop (the cosign signing we still
  rely on for provenance; just not for admission)
- ADR-0019 — Binary drift blocks via readOnlyRootFilesystem (the
  defence-in-depth layer at runtime; this ADR adds the layer at
  admission)
- ADR-0020 — Defender Helm from cnapp-lab (this ADR fixes a chart bug
  introduced there)
- ADR-0021 — Image Integrity scaffolded pause (this ADR explains why
  the scaffolded path didn't reach the finish line)
