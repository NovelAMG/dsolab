# GHAS License & Story Alignment

> **Purpose of this doc**: capture the current state of GitHub Advanced Security
> (GHAS) licensing for our DevSecOps lab, how our setup aligns (or doesn't) with
> Microsoft's published Defender for Cloud DevOps integration story, and what
> would change if we migrate `NovelAMG/dsolab` from a personal account to a
> GitHub Enterprise org with GHAS enabled. Drop this into a new chat to scope a
> migration plan.

---

## 1. TL;DR

- We are running the **OSS half** of Phase 2 supply-chain security on a public personal-account repo (`NovelAMG/dsolab`).
- We get the **scanning** half: CodeQL, secret scanning, push protection, Dependabot, Trivy, Checkov — all working, findings in GitHub Security tab + Defender for Cloud DevOps view.
- We do NOT get the **enrichment** half: runtime-aware alert prioritization, one-click GitHub issues with runtime context, code-to-runtime mapping, Copilot Autofix. **These all require a paid GHAS license**.
- A GHAS license requires a paid **GitHub Enterprise Cloud** subscription. **Cannot be bought standalone**. Cheapest entry point ≈ **$70/user/month** for one solo person.
- For our lab, the practical play is a **30-day free Enterprise Cloud trial** before the Phase 5 CVE-2025-68613 demo. Skip until then.

---

## 2. What GHAS actually is, license-wise

### Two paid SKUs (since 2024)

| SKU | What it gives you | List price |
|---|---|---|
| **GitHub Secret Protection** | Secret scanning, push protection, AI-based generic secret detection, validity checks | ~$19/active-committer/month |
| **GitHub Code Security** | CodeQL, Copilot Autofix, dependency review, security overview, security campaigns | ~$30/active-committer/month |
| Both combined (older "GHAS" bundle) | Everything above | ~$49/active-committer/month |

### Prerequisite: GHEC subscription

GHAS is an **add-on**, never sold standalone. You first need:

| GitHub plan | Monthly cost | Can buy GHAS? |
|---|---|---|
| Free (personal) | $0 | ❌ |
| Pro (personal) | ~$4/user | ❌ |
| Team (org) | ~$4/user | ❌ |
| **Enterprise Cloud (org)** | **~$21/user** base | ✅ |
| **Enterprise Server (self-hosted)** | ~$21/user | ✅ |

**Bottom-line cost for one solo developer wanting GHAS on a private repo:**

```
GitHub Enterprise Cloud:  $21/user/mo
+ GHAS bundle:            $49/user/mo
= $70/user/month  →  $840/year for one person
```

### Minimum seats

| Buying channel | Minimum seats | Notes |
|---|---|---|
| **Self-serve at github.com** | **1 seat** | Solo dev, can buy via UI |
| **Azure Marketplace** | Usually 1 for GHEC; GHAS add-on minimum varies | Bill through existing Azure subscription |
| **GitHub Sales / Microsoft Volume Licensing** | **25–50 seats** | Enterprise procurement |

### "Active committer" billing — the catch

- Counted: anyone who pushed to ANY repo in the org in the last 90 days (not just GHAS-enabled repos)
- Contractor who pushes once → counts for 90 days
- Bot accounts that push → count (some bots excluded: Dependabot, GitHub Actions tokens)
- Resets only after 90 days of inactivity from that user
- For a solo lab: 1 active committer = 1 billed seat

### Free 30-day Enterprise trial

- `github.com/enterprise` → "Start free trial"
- Full Enterprise Cloud + GHAS features
- No commitment, cancel before day 30 → no charge
- **This is the practical demo path** — light it up just before Phase 5

---

## 3. Our current alignment vs Microsoft docs

Three Microsoft Learn docs define what "Defender for Cloud + DevOps" looks like in
the published story. Here's how our setup measures up.

### 3.1 Doc — GHAS integration with Defender for Cloud

[learn.microsoft.com/.../github-advanced-security-overview](https://learn.microsoft.com/en-us/azure/defender-for-cloud/github-advanced-security-overview)

| Prerequisite | Our state | Status |
|---|---|---|
| GitHub connector to Defender | ✅ `personal-github-repo` connector live | ✅ |
| Defender CSPM enabled | ✅ on subscription `e406a385-feed-47ce-9194-13ed4f88f094` | ✅ |
| **GHAS license** | ❌ — `dsolab` is on personal account, no GHEC, no GHAS | ❌ |
| Security Admin + GH org owner roles | ✅ | ✅ |

**Verdict: Partial alignment.**

What works for us today:
- ✅ Connector ingests our CodeQL alerts (public-repo CodeQL is free)
- ✅ Defender's own agentless scanners (Trivy, Checkov, ESLint, Bandit, Template Analyzer) populate Defender portal findings independently

What we DON'T get without the GHAS license:
- ❌ **Production-aware alert prioritization** — the "this CVE is in code that's internet-exposed in AKS" overlay enriching GitHub Security tab
- ❌ **Unified AI-driven remediation** — one-click "create GitHub issue with full SDLC + runtime context, assigned to CODEOWNERS"
- ❌ **Runtime Risk Factors** (Internet Exposure, Sensitive Data, Critical Resources, Lateral Movement) bubbling back into GitHub
- ❌ **Copilot Autofix** for code findings

This is also why the Defender portal shows `dsolab` with **"Advanced security: Off"** badge — the badge specifically reads the GHAS license flag.

### 3.2 Doc — Container image mapping (code-to-runtime)

[learn.microsoft.com/.../container-image-mapping](https://learn.microsoft.com/en-us/azure/defender-for-cloud/container-image-mapping)

| Prerequisite | Our state | Status |
|---|---|---|
| Defender CSPM | ✅ | ✅ |
| Image built through a CI/CD pipeline | ❌ — built locally via `scripts/08-build-and-push-spa.sh` | ❌ |
| Image discoverable (in ACR or running in K8s) | ✅ both | ✅ |

Three mapping methods exist in the doc — we have **none**:

| Option | What | Our state |
|---|---|---|
| 1. Auto via connector | Image built+pushed from GitHub Actions, connector auto-maps | ❌ we push from laptop, not Actions |
| 2. Docker LABELs | `LABEL org.opencontainers.image.source=...` in Dockerfile (OCI annotation) | ❌ Dockerfile has no source labels |
| 3. GitHub attestations | `actions/attest-build-provenance` step in CI workflow | ❌ no attestation step exists |

**Verdict: Not aligned.**

**Why it matters for Phase 5**: when we detonate CVE-2025-68613, MSEM should draw an attack-path graph: *"vulnerable image → AKS pod → exposed via ingress → ...mapped back to PR #N"*. Without code-to-cloud mapping, the trace breaks at the image — we can't link back to which PR introduced the vulnerable version.

**Easy fix today** (no GHAS license needed):

```dockerfile
# spa/Dockerfile — add OCI labels (Option 2)
LABEL org.opencontainers.image.source="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.revision="${VITE_GIT_SHA}"
```

Plus `--build-arg VITE_GIT_SHA=$(git rev-parse HEAD)` in the build script.

**Better fix**: move SPA build into GitHub Actions and add `actions/attest-build-provenance` — gives Option 1 (auto) + Option 3 (attestation) simultaneously, plus reproducible builds. This is what's tracked as **Phase 3.6** in the lab plan.

### 3.3 Doc — IaC template mapping

[learn.microsoft.com/.../iac-template-mapping](https://learn.microsoft.com/en-us/azure/defender-for-cloud/iac-template-mapping)

| Prerequisite | Our state | Status |
|---|---|---|
| Defender CSPM | ✅ | ✅ |
| **Azure DevOps** environment in Defender | ❌ — we use GitHub Actions | ❌ (blocking) |
| Azure Pipelines running MSDO with `IaCFileScanner` | ❌ | ❌ (blocking) |
| Tag values are GUIDs (`yor_trace` / `mapping_tag`) | ❌ — semantic tags only | ❌ |
| Supported template language | ✅ Terraform | ✅ |

**Verdict: Not applicable — feature is Azure DevOps only.**

As of the doc's last update (June 2025), the MSDO IaC file scanner mapping logic was built for ADO pipelines and hasn't been ported to GitHub Actions. To unlock IaC template mapping today, we'd need to mirror the repo to ADO and run MSDO there. Not worth it for a lab.

**What we still get on GitHub today**:
- ✅ Defender's agentless Checkov scan (already on) finds misconfigurations in our TF files
- ❌ Does NOT link "this storage account that exists in Azure" back to "this `azurerm_storage_account` block in this commit"

Track for "when Microsoft ships this for GitHub". No action.

---

## 4. Migration considerations — personal account → org with GHAS

If/when we decide to flip on GHAS, the simplest path is to move `dsolab` into a
new org under the same `tonzking123` account and trial GHEC for 30 days.

### Standard GHEC vs Enterprise Managed Users (EMU)

| Flavor | How you log in | Picks |
|---|---|---|
| **Standard GHEC (with personal accounts)** | Same `@tonzking123` you use today | Solo, lab, small team, anyone wanting flexibility |
| **EMU — Enterprise Managed Users** | New dedicated account `tonzking123_<orgname>` that ONLY exists inside the enterprise | Banks, regulated industries, strict SSO/lifecycle requirements |

**For our lab: standard GHEC.** Personal account stays, just gets invited as the org's owner.

### What changes in the standard GHEC model

| Thing | Personal account | Org context |
|---|---|---|
| Login credentials | Same | Same |
| 2FA / passkey | Same | Required by enterprise policy if admin enforces |
| Personal repos (e.g., scratch repos) | Yours, unchanged | N/A |
| Org repos (`dsolab` after transfer) | N/A | New, owned by org |
| Profile / contribution graph | Yours | Contributions count both places |
| Billing for personal GitHub Pro | You pay if you want it | Enterprise pays for your seat |
| Personal Copilot subscription | You pay | Enterprise can also give you Copilot Business — both can coexist |

### Where to check GHAS / security features after migrating

| URL | What it shows |
|---|---|
| `github.com/organizations/<ORG>/settings/security_analysis` | **Org-level toggles** — the single source of truth for which security features are licensed and on |
| `github.com/organizations/<ORG>/billing/seats` | Seat count + GHAS active committer count + actual line items being billed |
| `github.com/enterprises/<ENT>/settings/policies/code_security` | Enterprise-wide policies across all orgs (only if you have an Enterprise Account, not regular orgs) |
| `github.com/<ORG>/<REPO>/settings/security_analysis` | Per-repo override of org-level settings |
| `github.com/<ORG>/<REPO>/security` | Actual findings (Security tab) |

### CLI shortcuts

```bash
# Your account + orgs you belong to
gh api user
gh api user/orgs --jq '.[].login'

# Org plan tier (look for plan.name)
gh api orgs/<ORG-NAME> --jq '{plan, default_repo_permission, two_factor_requirement_enabled}'

# Org-wide GHAS billing — only works IF GHAS is purchased
gh api orgs/<ORG-NAME>/settings/billing/advanced-security \
  --jq '{committers: .total_advanced_security_committers, cost: .estimated_paid_advanced_security_committers}'

# Repo-level security flags (works without GHAS, shows what's on per repo)
gh api repos/<ORG>/<REPO> --jq '.security_and_analysis'

# Across all repos in an org — find which have GHAS enabled
gh api orgs/<ORG-NAME>/repos --paginate \
  --jq '.[] | {name: .name, ghas: .security_and_analysis.advanced_security}'
```

### Migration step-by-step (the trial path)

```
1. github.com/account/organizations/new
   → create a free org (e.g., tonzking-lab)

2. github.com/organizations/tonzking-lab/billing/upgrade
   → start "Enterprise Cloud" 30-day trial

3. github.com/NovelAMG/dsolab/settings
   → Transfer ownership → new owner = tonzking-lab
   → Old URL auto-redirects

4. github.com/organizations/tonzking-lab/settings/security_analysis
   → Enable GitHub Advanced Security
   → Enable for new repositories
   → Confirm seat count (1)

5. Wait ~10 minutes, then check
   Defender for Cloud → DevOps security → dsolab
   → Badge should flip from "Off" to "Advanced security: On"

6. Run Phase 5 demo with full code-to-runtime correlation

7. Before day 30:
   github.com/organizations/tonzking-lab/billing → cancel trial
   OR transfer the repo back to your personal account first
```

### Things that WILL break if not handled during migration

The migration breaks several Azure/GitHub integration points that we set up
during Phase 1. Each needs an explicit update:

| What breaks | Why | How to fix |
|---|---|---|
| **TF apply workflow (OIDC)** | Federated credential on `mi-gha-dsolab` MI is bound to `repo:NovelAMG/dsolab:ref:refs/heads/main` and `repo:NovelAMG/dsolab:pull_request` | Update FIC subjects via Terraform or `az identity federated-credential update` to `repo:tonzking-lab/dsolab:...` |
| **Defender DevOps connector OAuth scope** | OAuth grant scoped to `tonzking123` org with explicit repo list (`dsolab`, `DevSecOps-Demo`) | Update grant via GitHub App settings to include `tonzking-lab` org + `dsolab` repo |
| **Workflow file references to repo path** | Cosmetic — comments or error messages mention `NovelAMG/dsolab` | Search & replace in `.github/workflows/*.yml` and `scripts/*.sh` |
| **Branch protection rule on `main`** | Stays — it's per-repo | None |
| **Open PRs** | Stay — PR numbers preserved | None |
| **Issue history** | Stays — moves with the repo | None |
| **Dependabot config** | Stays — `.github/dependabot.yml` moves with repo | None |

### Things that just keep working

- GitHub Actions workflows (after the OIDC FIC update)
- All scan results (Trivy, Checkov, CodeQL) — they re-run on the new path and re-populate Security tab
- ACR push (uses the same MI, which is Azure-side)
- AKS deployment (uses the same `mi-n8n-aoai-dsolab` workload identity, no change)
- Issue #17 (Checkov triage tracker)
- All ADRs in `docs/decisions/`
- The chat at `https://chat.20.195.16.7.nip.io/` keeps running (it's all in AKS, not GitHub)

---

## 5. Decision matrix — should we do it?

| Question | Answer |
|---|---|
| Forced minimum seats for self-serve? | No (1 minimum) |
| Forced minimum seats via Microsoft EA? | Yes (typically 25+) |
| Worth buying for personal lab? | **No** — $840/year for cosmetic badge + features only used during demo |
| Worth a free 30-day trial? | **Yes — for the Phase 5 demo specifically** |
| Will it hurt our Phase 5 if we don't have it? | You miss the MSEM "PR → image → pod → exploit" graph back-half, but you still get all the alerts. Lab pedagogy works without it. |
| Should we migrate to org NOW? | **No** — wait until 1-2 days before Phase 5 demo |
| What can we fix WITHOUT GHAS today? | Container image mapping via Docker LABELs (Option 2 from §3.2) — closes one alignment gap for free |

---

## 6. Recommended next moves (independent of GHAS)

These improve our alignment WITHOUT touching the GHAS license:

| # | Action | Cost | Alignment win |
|---|---|---|---|
| 1 | Add OCI LABELs to `spa/Dockerfile` (Option 2 from §3.2) | 5 min | Container image mapping starts working |
| 2 | Move SPA build to GitHub Actions (Phase 3.6 in lab plan) | 1-2 hours | Container image mapping via Option 1 (auto) and Option 3 (attestation); also enables cosign signing for Phase 3.7 Ratify |
| 3 | File ADR documenting the GHAS license deferral (this doc → ADR) | 10 min | Provenance / audit trail |
| 4 | File ADR documenting IaC template mapping as N/A (ADO-only) | 5 min | Provenance |
| 5 | (Optional, day-of) 30-day GHEC trial + org migration playbook above | 1 hour setup + 30 min teardown | Full Defender-for-Cloud + GHAS story for Phase 5 demo |

---

## 7. Open questions for the next chat

If you take this doc to a fresh chat to scope migration, here's what they should
ask before doing anything destructive:

1. **Are we migrating for keeps, or just for a demo?** The trial path vs the buy path have different recommendations.
2. **Will `tonzking123` stay the human owner, or will we add other collaborators?** Affects the active-committer count (and therefore cost) once on a paid plan.
3. **Do we want the org name to be something brandable** (`devsecops-lab`, `acme-security-lab`) **or just `tonzking-lab`?** Affects URLs, FIC subjects.
4. **Are we OK transferring all repos under `tonzking123`, or just `dsolab`?** Bulk transfer is simpler; partial means maintaining two contexts.
5. **Do we want to enforce SAML SSO / 2FA at org level?** Locks down nicely but adds friction for solo work.
6. **Is the Azure connector `personal-github-repo` going to be renamed / re-grant scoped to the new org?** Affects the consent flow and ID URLs.
7. **What's the rollback plan if Defender stops ingesting after migration?** OAuth re-grant + FIC update steps from the table above.

---

## References

- [GitHub Advanced Security overview (Defender for Cloud)](https://learn.microsoft.com/en-us/azure/defender-for-cloud/github-advanced-security-overview)
- [Container image mapping](https://learn.microsoft.com/en-us/azure/defender-for-cloud/container-image-mapping)
- [IaC template mapping](https://learn.microsoft.com/en-us/azure/defender-for-cloud/iac-template-mapping)
- [GitHub Advanced Security pricing & SKUs](https://github.com/enterprise/advanced-security)
- [GitHub Enterprise Cloud plan comparison](https://github.com/security/plans)
- [Azure Marketplace — GitHub Advanced Security](https://azuremarketplace.microsoft.com/marketplace/apps/github.advanced-security)

---

*Generated 2026-05-24 as a hand-off doc for migration scoping. Pair with `plan.md`, `phase2.html`, and `demo.html`.*
