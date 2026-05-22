# ADR 0004 — Split Azure OpenAI to `australiaeast` while AKS stays in `southeastasia`

**Status**: Accepted
**Date**: 2026-05-22
**Phase**: 1A

## Context

The lab is hosted in Southeast Asia for the user's geographic proximity. Azure OpenAI is available in `southeastasia` but **GPT-4o model availability there is historically limited** (often only `gpt-4o-mini` or `gpt-35-turbo`). The full GPT-4o model is reliably available in `eastus2`, `swedencentral`, and `australiaeast`.

Three options were considered:
- **A** — Single region SEA: AKS + AOAI both in `southeastasia`, accept whatever model is available (likely `gpt-4o-mini`).
- **B** — Split: AKS in `southeastasia`, AOAI in `australiaeast`. ~80ms latency penalty SG↔SYD per AOAI call.
- **C** — Single region AUE: AKS + AOAI both in `australiaeast`. Further from user.

## Decision

Choose **Option B**: AKS + ACR + KV + Postgres + LA in `southeastasia`; Azure OpenAI account + GPT-4o deployment in `australiaeast`.

## Why B

- **Model availability is non-negotiable for the lab story**: Phase 4 (Defender for AI Services) and Phase 5 (CVE detonation with jailbreak detection) are most credible with a real GPT-4o backend.
- **80ms extra latency is invisible at chat speeds**: the user-perceived response time is dominated by the LLM inference (1–3 seconds), not the network hop.
- **End-user latency stays low**: the SPA → ingress → oauth2-proxy → n8n path is all in SEA, so the user experiences SEA latency to the app surface. Only the n8n → AOAI hop pays the cross-region cost.
- **Same resource group**: keeping everything in `rg-dsolab-sea` (the RG location is metadata; resources within can be in any region). Simpler cleanup, simpler Defender enablement.

## Implications for later phases

- **Phase 3.3 (ingress hardening)**: when we add a private endpoint for AOAI, it lives in a VNet in `australiaeast`. We'll either (a) keep AOAI on its public endpoint behind WAF / IP allowlist for the lab, or (b) peer the SEA AKS VNet to an AUE VNet hosting the AOAI private endpoint. Option (a) is simpler for the lab; (b) is more production-realistic. Defer the choice to Phase 3.
- **Phase 4.1 (Conditional Access for workload identity)**: the IP-range restriction on `mi-n8n-aoai` must allow the AKS egress IP (SEA region) reaching the AOAI endpoint (AUE region). Standard cross-region traffic; no special config needed.
- **Cost**: AOAI calls cross-region in Azure are free for egress (within Azure backbone, single tenant). No surprise bill.

## When to reconsider

If `southeastasia` gains reliable GPT-4o capacity later, collapse to Option A. The Terraform change is one variable flip (`location_aoai = "southeastasia"`) + redeploy the AOAI module. The rest of the lab is unaffected.
