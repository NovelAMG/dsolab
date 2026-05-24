# ADR 0017: SPA build+push+sign runs in CI, not from a laptop

- **Status**: Accepted
- **Date**: 2026-05-24
- **Phase**: 3.6 (build-time provenance)

## Context

Phase 3.7 will enable Defender for Cloud Image Integrity (ADR 0016) — an
admission controller that rejects pods unless their container images are
signed by a trusted OIDC identity.

For that to be meaningful, the signing identity must be **portable,
auditable, and not tied to any individual human**. Two paths were possible
for the cosign signing step in Phase 3.6:

| Path | Where signing happens | Signer identity |
|---|---|---|
| **A — local script** | `scripts/08-build-and-push-spa.sh` on the engineer's laptop | The engineer's local cosign keypair OR their personal GitHub OIDC token |
| **B — CI workflow** (chosen) | `.github/workflows/build-spa.yml` on a GitHub-hosted runner | `repo:NovelAMG/dsolab:ref:refs/heads/main` GitHub OIDC subject |

Until today, the SPA was built and pushed manually via the local script.
There was no CI for the SPA — only Terraform had CI/CD.

## Decision

**Build, push, and sign the SPA image in CI** (Path B), triggered on every
push to `main` that touches `spa/**`. The local script stays for dev
iteration but production images flow through git history.

## Rationale

1. **Cosign signing only works if the signer is trustworthy.** A signature
   from "Thobthuan's laptop" tells admission "trust whoever has Thobthuan's
   laptop today" — including a stolen laptop, a borrowed one, or
   credential-stuffed cosign keys. A signature from
   `repo:NovelAMG/dsolab:ref:refs/heads/main` tells admission "trust
   what our main branch's CI produced" — cryptographically tied to the
   GitHub OIDC issuer and the exact workflow file path.

2. **Phase 3.7's Image Integrity policy becomes portable.** The policy
   matches a constant OIDC subject derived from the repo path, not a
   human's certificate. If we add a second engineer, no policy change.

3. **Closes the missing CI piece for the SPA.** Up to now, the only way
   to update the SPA was a manual local command (PR merge alone did
   nothing). With this workflow, PR merge to `main` on `spa/**`
   automatically produces a new signed image in ACR. The deploy step
   (`scripts/09-deploy-spa-and-workflow.sh`) is still manual — that's a
   deliberate keep-it-simple split for the lab.

4. **The build environment is reproducible.** GitHub-hosted runner =
   pinned Ubuntu image + pinned action versions in YAML. Local builds
   on macOS Apple Silicon required explicit `--platform linux/amd64`
   forcing — easy to forget; the workflow can't forget.

5. **OIDC means no secrets.** The workflow uses the same managed
   identity that runs Terraform (`mi-gha-dsolab`) for ACR push, and
   GitHub OIDC for Sigstore. Zero credentials added to `gh secret list`.

## Alternatives considered

- **Path A (local script + cosign)**. Rejected per the rationale above.
- **Self-hosted runner**. Overkill for a lab; doesn't change the identity
  model.
- **Build in CI, sign separately on a self-hosted signer**. Over-engineered;
  cosign keyless on the same runner is the recommended Sigstore pattern.
- **Move deploy into CI too** (full GitOps to AKS). Worth doing, but
  deferred — the cluster doesn't currently have a deploy identity wired
  in. Not blocking 3.7.

## Consequences

### Positive

- Every image in ACR has a signature traceable to a specific commit + a
  specific workflow run. `cosign verify` outputs the SHA, workflow file
  path, and run number.
- The local script becomes "dev iteration only" — production builds
  cannot accidentally land in main without an audit trail.
- Phase 3.7's admission policy can reference a stable OIDC subject:
  `https://github.com/NovelAMG/dsolab/.github/workflows/build-spa.yml@refs/heads/main`.
- Adds a second meaningful CI workflow for the application (alongside
  the security gates from Phase 2), making the lab look more like a
  realistic production setup.

### Negative

- Slower iteration: editing SPA code → PR → merge → wait ~3 min for CI
  → manually trigger `scripts/09-deploy-spa-and-workflow.sh` with new
  tag. Today it's edit → run script → ~90 sec.
- Mitigation: keep the local script available; document that it's the
  fast-feedback path for active development. Use CI for anything that
  reaches main.
- The local script's signature would NOT match the Image Integrity
  policy in 3.7, so locally-built images cannot be deployed to the
  `n8n` namespace once 3.7 is on. This is by design — if you need to
  test an unsigned dev image, deploy it to a different namespace (or
  temporarily exempt your dev namespace from the policy).

### Operational

- Required GitHub variables (already present): `AZURE_CLIENT_ID`,
  `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `SPA_APP_ID`,
  `N8N_API_APP_URI`, `INGRESS_HOST`.
- ACR push is granted via the existing GHA MI's Contributor role on the
  resource group (covers AcrPush). No new role assignment.
- The cosign signature lives as an OCI artifact in the same ACR
  (`acrdsolabxsqb`), discoverable via `oras discover -o tree <image>`.
- Verification command pinned in the workflow's job summary, ready to
  copy.

## Related

- ADR 0016 — Use Defender Image Integrity over raw Ratify (the consumer
  of these signatures)
- Phase 3.7 — admission gate that will trust this workflow's OIDC subject
- `scripts/08-build-and-push-spa.sh` — kept for dev iteration; banner
  added pointing at this workflow for production builds
