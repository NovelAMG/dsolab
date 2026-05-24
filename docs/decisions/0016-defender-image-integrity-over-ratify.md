# ADR 0016: Use Defender for Cloud Image Integrity instead of raw Ratify

- **Status**: Accepted
- **Date**: 2026-05-24
- **Phase**: 3.7 (admission / gated deployment)

## Context

Phase 3.7 needs an **admission controller** that rejects pods whose container
images don't meet our policy: must be **signed by our CI's GitHub OIDC
identity** AND should have no **Critical CVE** findings.

Two paths to deliver this on AKS:

1. **DIY Ratify**: Install [Ratify](https://ratify.dev/) directly via Helm.
   Configure verification policies (signature, SBOM, vulnerability reports)
   as Ratify CRDs. We own upgrades and policy syntax.
2. **Defender for Cloud Image Integrity** (preview, 2026): Toggle on in
   Defender portal (or `az aks update --enable-image-integrity`). Microsoft
   installs and manages Ratify in `gatekeeper-system`. Policies expressed
   as **Azure Policy assignments**.

Both use Ratify under the hood. The difference is who manages it and where
the policy lives.

## Decision

**Use Defender for Cloud Image Integrity** (option 2).

## Rationale

| Dimension | Raw Ratify (Helm) | Defender Image Integrity | Winner for our lab |
|---|---|---|---|
| Upgrade management | We do it | Microsoft does it | Defender |
| Policy syntax | Ratify CRDs (custom) | Azure Policy (familiar — we already use it) | Defender |
| Findings dashboard | Cluster events + Falco-style | Defender for Cloud portal (already our nerve centre) | Defender |
| Gates on signature | ✅ | ✅ | tie |
| Gates on **vulnerability findings** (MDVM CVEs) | Requires custom verifier + SBOM glue | ✅ built-in (one policy, two criteria) | Defender |
| Cost | Free (OSS) | Already paying for Defender for Containers; no marginal cost | tie |
| Lock-in | Portable | Azure-specific | Ratify wins (but we are Azure-only) |
| Maturity | GA upstream | Preview in Defender | Ratify wins (slightly) |
| Rule expressiveness | Higher (custom Rego, complex SBOM checks) | Lower (Azure Policy built-ins + a few custom params) | Ratify wins |

Net: for a single Azure-only lab where Defender for Containers is already
paid for and on, the Defender path gives us **(a) one less moving piece to
maintain, (b) one policy that gates on both signature and vulnerability,
and (c) findings in the same dashboard as everything else**.

## Alternatives considered

1. **Helm-install Ratify directly** (rejected above). Considered if/when we
   need rule expressiveness Azure Policy can't deliver (e.g., complex
   SBOM-license enforcement). Easy to swap to later — both paths produce
   `Image Integrity` admission events.
2. **OPA Gatekeeper with cosign verification plugin**. Heavier; doesn't
   integrate with Defender's vulnerability findings; doesn't add value
   over Ratify.
3. **Skip admission entirely, rely on Defender for Containers runtime
   detection**. Defeats the "Ship → Deploy gate" goal. Runtime detection
   is reactive; admission is preventive.

## Consequences

### Positive
- Single Azure Policy assignment defines both signature and CVE gating.
- Defender for Cloud handles Ratify lifecycle (no chart pinning, no `helm
  upgrade` cron).
- Image Integrity events flow into Defender portal → Recommendations and
  Security alerts alongside all other supply-chain signals.
- Pairs naturally with the existing Defender for DevOps connector
  (PR #16 work via 3.2): scan-time findings in CI → admission-time block
  in cluster, same Microsoft-managed pipeline.

### Negative
- **Preview feature.** API may change; documentation lags. Mitigation:
  scope to `n8n` namespace only at first; document the policy assignment
  ARM/Bicep so we can recreate it if Microsoft renames things.
- **Less rule expressiveness** than upstream Ratify. If we ever need
  e.g. "image must have SBOM AND SBOM must declare LICENSE=Apache-2.0",
  Defender's policy may not express it; we'd add a second Ratify policy
  alongside (Ratify supports multiple verifiers).
- **Lock-in.** Migrating off Defender for Containers means re-implementing
  the policy in raw Ratify. Acceptable: we're Azure-only and the gate
  logic is small.

### Operational
- 3.6 (cosign signing) must land first — Image Integrity has nothing to
  verify without signatures.
- 3.7 enablement is one CLI command + one Azure Policy assignment scoped
  to `n8n`. Both will be code-reviewed via PR (Terraform for the policy
  assignment).
- The negative test for verification (`kubectl run x --image=nginx -n n8n`
  → REJECTED) must be re-run after any AKS upgrade in case Microsoft
  changes the Image Integrity webhook behavior in preview.

## Related

- ADR 0001 — Defer Defender sensor (deferral ended 2026-05-23; sensor now
  on; Image Integrity webhook deploys alongside it).
- ADR 0015 — Phase 2 supply-chain gates (Trivy/Checkov in CI). 3.7 closes
  the loop by enforcing at the cluster.
- Phase 3.6 — cosign signing in CI (produces the signatures Image
  Integrity will verify).
- Microsoft docs: [Gated deployment for Kubernetes container images](https://learn.microsoft.com/en-us/azure/defender-for-cloud/runtime-gated-overview).
