# DevSecOps Lab — `dsolab`

End-to-end DevSecOps learning lab on Azure: SPA + n8n + Azure OpenAI on AKS, secured with Microsoft Defender for Cloud, GitHub Advanced Security, and Entra ID — built in 6 phases.

📖 **Full plan**: [plan.md](plan.md) · [plan.html](plan.html) (open in browser)

## What this lab demonstrates

- A working AI agent (n8n) called from a web SPA, fronted by oauth2-proxy with Entra ID auth.
- Azure OpenAI accessed via Workload Identity (no API keys; `disableLocalAuth: true`).
- Layered DevSecOps controls: GHAS shift-left, Defender for Cloud CLI, admission control, runtime threat detection, AI SPM, Conditional Access.
- Detonation of a real CVE (CVE-2025-68613 — n8n authenticated RCE) with a 9-layer detection scorecard.

## Lab parameters

| Item | Value |
|---|---|
| AKS region | `southeastasia` |
| Azure OpenAI region | `australiaeast` (split for GPT-4o availability) |
| Naming prefix | `dsolab` |
| GitHub repo | `tonzking123/dsolab` |
| Lab FQDN | `chat.<ingress-IP>.nip.io` (no DNS to manage) |

## Prerequisites

Before running the bootstrap script:

1. **Azure subscription** with Owner-level access (needed to create role assignments).
2. **Azure CLI** (`az`) ≥ 2.60, logged in (`az login`).
3. **GitHub CLI** (`gh`), logged in (`gh auth login`) with `repo` scope.
4. **Terraform** ≥ 1.6.
5. The empty repo `tonzking123/dsolab` exists on GitHub.

## Phase 1A — quick start

```bash
# 1. Run the one-time bootstrap (creates state SA + GitHub OIDC plumbing)
chmod +x scripts/00-bootstrap-state.sh
./scripts/00-bootstrap-state.sh

# 2. Commit + push to a feature branch
git checkout -b infra/01-bootstrap
git add .
git commit -m "chore: scaffold repo with bootstrap, providers, and hello-world workflow"
git push -u origin infra/01-bootstrap

# 3. Open a PR — the hello-world workflow should turn green within ~60 seconds.
gh pr create --fill
gh pr view --web
```

When the workflow goes green, you've proven GitHub → Azure auth works **with zero secrets**. That's the Phase 1A win.

📖 **Detailed walkthrough**: [docs/runbook-phase-1a.md](docs/runbook-phase-1a.md)

## Repo structure

```
.
├── plan.md, plan.html              # Full multi-phase plan (source of truth)
├── README.md                       # You are here
├── .gitignore
├── scripts/
│   └── 00-bootstrap-state.sh       # 1A — one-time: TF state SA + GH OIDC MI
├── terraform/
│   └── envs/lab/                   # 1A — providers, backend, variables (modules in 1B)
├── .github/workflows/
│   └── hello-world.yml             # 1A — OIDC smoke test
└── docs/
    ├── decisions/                  # ADRs
    │   ├── 0002-use-terraform-not-bicep.md
    │   ├── 0003-drop-entra-agent-id.md
    │   ├── 0004-split-aoai-to-australiaeast.md
    │   └── 0005-nip-io-for-lab-fqdn.md
    └── runbook-phase-1a.md         # Step-by-step for the first PR
```

## Phase status

- [x] Phase 0 — prerequisites (you have Azure, GitHub, tools)
- [ ] **Phase 1A — repo bootstrap + OIDC** ← you are here
- [ ] Phase 1B — core infra (AKS, ACR, AOAI, Postgres, KV)
- [ ] Phase 1C — Defender posture decision (sensors OFF until Phase 3)
- [ ] Phase 1D — workload identity + Entra app regs
- [ ] Phase 1E — n8n + oauth2-proxy + SPA on AKS
- [ ] Phase 1F — token flow + golden smoke test
- [ ] Phase 2 — shift-left security (GHAS + Defender CLI)
- [ ] Phase 3 — cluster & runtime security (admission, NetworkPolicy, Defender Containers)
- [ ] Phase 4 — identity & AI SPM (Conditional Access + Defender for AI + Purview DSPM)
- [ ] Phase 5 — detonate CVE-2025-68613 with 9-layer detection scorecard
- [ ] Phase 6 — continuous monitoring (Sentinel + MSEM)
