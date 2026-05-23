# ADR 0015: Phase 2 — Supply-chain security gates (SAST + IaC + image + deps)

- **Status**: Accepted
- **Date**: 2026-05-23
- **Phase**: 2 (shift-left supply chain)

## Context

Phase 1 produced a working end-to-end chat path
(SPA → MSAL → oauth2-proxy → n8n → workload identity → AOAI). Nothing
about that path was gated: any code change could land on `main` without a
scan, any container could be pushed to ACR without a CVE check, any
Terraform change could weaken the network without an opinion from CI.

Phase 2 closes that gap. The goal is **nothing reaches `main` (and nothing
reaches the cluster) without being scanned by at least one independent
tool**, surfaced in a single place (the repo Security tab), and blocking
when severity is high.

## Decision

Five gates land together in a single PR, all wired to push-to-main and
pull-request-to-main:

| # | Gate | Tool | Trigger | Blocking? |
|---|---|---|---|---|
| 2A | SAST (TypeScript) | CodeQL `security-extended` | spa/** | informational (Security tab) |
| 2B | Secret scanning | GitHub native | repo-wide, always on | yes (push protection) |
| 2C | Dependency updates | Dependabot (npm, actions, terraform, docker) | weekly + security alerts | informational (PRs) |
| 2D | Container image | Trivy + SARIF | spa/**, weekly cron | **yes** on HIGH/CRITICAL fixed |
| 2E | IaC + K8s | Checkov + SARIF | terraform/**, k8s/**, Dockerfile | **yes** on any non-allowlisted finding |

### Tool choices

**CodeQL over Semgrep**: free for public repos, GitHub-native, results land
in the same Security tab as Trivy/Checkov SARIF, no third-party setup.
Semgrep is a reasonable swap if we later go private and don't want to
license GHAS — the SARIF shape is portable.

**Trivy over Snyk / Defender CLI** *at this phase*: Trivy runs entirely in
CI with no Azure dependency, no plan toggle, no MI. Fast PR feedback in
~30s. Defender for Containers (registry scan) joins in **Phase 3** as the
*second* line of defence — same image, scanned again after push, with
Defender's curated context (runtime exploitability, asset inventory).
Two independent scans of one artefact is a feature, not duplication.

**Checkov over tfsec / kube-linter**: Checkov spans Terraform + K8s +
Dockerfile in one tool with one allowlist file, which keeps the
"acceptable findings" inventory in one place. tfsec is narrower (TF only)
and kube-linter doesn't cover IaC. Checkov has more false positives at
default — handled with `.checkov.yaml` baseline.

### Severity / blocking policy

- **Image scan (Trivy)**: fail on `HIGH,CRITICAL` with `--ignore-unfixed`.
  Rationale: we won't ship a fixable CVE; we can't fix what upstream
  hasn't fixed yet. Unfixed findings still show in the Security tab.
- **IaC (Checkov)**: any finding not on the allowlist fails. Allowlist
  entries MUST cite a reason. No silent skips.
- **SAST (CodeQL)**: informational — Security tab is the source of truth.
  We don't auto-block PRs on CodeQL because TS/React projects routinely
  flip between high-noise queries with each release; a weekly review
  of the Security tab is the realistic loop for a lab.
- **Secret scanning push protection**: already on (GitHub native), blocks
  at push time, not in CI.
- **Dependabot**: opens PRs. Security updates auto-open (separate from
  grouped version updates). Merging is manual after the other gates pass.

### What's deferred to Phase 3

- Defender for Containers registry scan on ACR (Azure-side second scan)
- Defender for Cloud recommendations as a CI gate (`az` Resource Graph)
- Image signing (cosign) + admission policy that rejects unsigned images
- TLS prod (Let's Encrypt prod, not staging)
- Network policies (cilium-based, lock down namespaces)

### What's deferred to Phase 4

- Image digest pinning (forces a controller flow we haven't built yet)
- SBOM generation + attestation (Trivy can emit SPDX, but no consumer yet)
- Runtime detection (Defender for Containers data-plane sensor — costs
  extra and we deferred Defender entirely until later, per ADR 0001)

## Consequences

### Positive

- Every PR runs five independent scans; results converge in the Security
  tab as SARIF.
- Dependabot opens grouped low-noise PRs for routine bumps, individual
  PRs for CVE fixes.
- Adding a new scan tool later is just another `.github/workflows/*.yml`
  + a SARIF upload — same shape as the existing gates.
- "Why was this accepted?" questions have answers: every Checkov skip
  cites an ADR or reason in `.checkov.yaml`.

### Negative

- First PR after merge may have to allowlist a few Checkov findings that
  weren't anticipated. Track them in `.checkov.yaml` with reasons.
- Trivy database refresh adds ~15s per PR run. Acceptable.
- Five workflows mean Actions minutes burn — public repo has generous
  free tier; not a concern at lab scale.

### Operational

- `gh api -X PATCH repos/{owner}/{repo} -F security_and_analysis.dependabot_security_updates.status=enabled`
  enables Dependabot security updates (the missing piece from the repo's
  current state).
- Branch protection rule for `main` requiring the four checks
  (CodeQL / Trivy / Checkov / Terraform plan) is **the next step**
  after this PR merges. Not added in the PR itself because protection
  rules can't be expressed as code in OSS GitHub without paying for the
  rulesets API (and would lock us out mid-PR if a check is misconfigured).

## Related

- ADR 0001 — Defender deferred to Phase 3 (informs the "two scans"
  rationale here)
- ADR 0014 — n8n vm2 sandbox quirks (Phase 1 close-out)
- PR #13 — the Phase 1 sync that this Phase 2 work builds on
