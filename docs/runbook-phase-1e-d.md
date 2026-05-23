# Runbook — Phase 1E-d: SPA + Azure OpenAI (the finale of Phase 1)

> **Goal:** open `https://chat.<ip>.nip.io/`, click "Sign in with Microsoft",
> type a message, get a real GPT-4o reply — all auth via Entra, all AOAI
> calls via workload identity, zero API keys on disk anywhere.
>
> **Win:** the assistant responds with text from gpt-4o.

---

## 0. End-to-end auth picture

```
Browser
  │ ① MSAL.js interactive login
  │   (popup) → Entra → access_token for api://9d3936a5-.../access_as_user
  ▼
NGINX Ingress
  ▼
oauth2-proxy  ←─── dual-mode (1E-d update):
  │                  • session cookie  → SPA pod
  │                  • Authorization: Bearer JWT (validated against Entra v2 issuer
  │                                              for audience api://9d.../) → n8n
  │
  ├── /             → SPA (React + nginx, served from ACR image)
  └── /webhook/chat → n8n
                       │ ② Read /var/run/secrets/azure/tokens/azure-identity-token
                       │ ③ Exchange federated token → AOAI access_token
                       │    (client_credentials + jwt-bearer assertion)
                       │ ④ POST /openai/deployments/gpt-4o/chat/completions
                       │    Authorization: Bearer <aoai-token>
                       │    body: { messages: [...], user: <caller-oid> }
                       ▼
                    Azure OpenAI (gpt-4o, australiaeast)
```

**Where the secrets live (or don't):**

| Thing | Where | Notes |
|---|---|---|
| SPA client ID | Baked into the SPA bundle at build time | Public — it's a SPA, this is fine (PKCE) |
| SPA -> n8n-api access token | Browser sessionStorage (MSAL default) | Cleared on tab close |
| oauth2-proxy client secret | K8s Secret (from KV) | Server-side, never leaves the pod |
| AOAI access token | Held in memory in the n8n Code node, lives ~1 hour | Never stored on disk |
| Federated SA token | Projected into the n8n pod by the WL identity webhook | 1-hour TTL, auto-rotated |
| AOAI **API key** | **DOES NOT EXIST** | `local_auth_enabled=false` on the AOAI account |

---

## 1. What this PR adds

| File | Purpose |
|---|---|
| `spa/` | Vite + React + TS + MSAL.js chat UI (~7 source files) |
| `spa/Dockerfile` | Multi-stage: `node:22-alpine` build → `nginx:alpine` serve (~50 MB image) |
| `spa/nginx.conf` | SPA fallback + healthz |
| `k8s/spa/{deployment,service}.yaml` | SPA pod (10m CPU, 16Mi RAM — tiny) |
| `k8s/n8n/workflow-import-job.yaml` | One-shot Job that runs `n8n import:workflow` then `update:workflow --active=true` |
| `k8s/oauth2-proxy/deployment.yaml` (modified) | Added `--skip-jwt-bearer-tokens` + `--extra-jwt-issuers` so it accepts MSAL bearer tokens; added SPA as the `/` upstream |
| `n8n-workflows/chat.json` | The n8n workflow (Webhook → Get AOAI token → Call AOAI → Respond) |
| `scripts/08-build-and-push-spa.sh` | Adds prod redirect URI to SPA app reg + builds + pushes to ACR |
| `scripts/09-deploy-spa-and-workflow.sh` | Applies SPA, restarts oauth2-proxy, creates ConfigMap from workflow JSON, runs import Job |
| `docs/runbook-phase-1e-d.md` | This file |

No Terraform changes.

---

## 2. Prereqs check

**What this does:** verifies everything 1E-d depends on is in place.

```bash
# n8n pod running
kubectl get pods -n n8n -l app=n8n

# Workload identity env actually injected
kubectl exec -n n8n deploy/n8n -- ls /var/run/secrets/azure/tokens/
# Expect: azure-identity-token

# Federated token + tenant + client id visible
kubectl exec -n n8n deploy/n8n -- env | grep ^AZURE_
# Expect: AZURE_CLIENT_ID=470f3d1d-..., AZURE_TENANT_ID=..., AZURE_FEDERATED_TOKEN_FILE=...

# SPA pre-authorized on n8n-api (no admin consent needed)
az ad app show --id 9d3936a5-6164-468f-a8e9-2daa56697474 \
  --query "api.preAuthorizedApplications[].appId" -o tsv
# Expect: b7643638-705f-4c5d-a7f9-03620fcc320f   (the SPA app id)

# Docker Desktop running locally
docker version
```

If any of these fail, fix before continuing.

---

## 3. Build + push the SPA image

**What this does:** the script ensures the SPA app reg has the prod redirect URI added, then `az acr login`, `docker buildx build` (forced linux/amd64 since you're on Apple Silicon), and pushes both `:<sha>` and `:latest` tags. ~2-3 minutes on a normal connection.

```bash
cd ~/Desktop/DevSecOps-True
./scripts/08-build-and-push-spa.sh
```

The build args inject the SPA's MSAL config into the bundle (client id, tenant, scope, redirect URI). These end up in the JS output and are visible in DevTools — that's expected and safe for a public client.

---

## 4. Deploy SPA + import the workflow

**What this does:** the script:
1. Adds `N8N_API_AUDIENCE` to `oauth2-proxy-secrets`
2. Re-applies oauth2-proxy with dual-mode args + restarts it
3. Applies the SPA Deployment/Service, pins the image tag from step 3
4. Creates a ConfigMap from `n8n-workflows/chat.json`
5. Runs the import Job (`n8n import:workflow` + `n8n update:workflow --active=true`)

```bash
./scripts/09-deploy-spa-and-workflow.sh
```

If the import Job fails (most common: n8n image version mismatch with workflow JSON schema), the script prints fallback instructions to import via the n8n UI.

---

## 5. Test the full flow

**Open `https://chat.<your-ip>.nip.io/` in a fresh InPrivate window.**

1. Cert warning → Advanced → Proceed (still LE staging until Phase 3)
2. **NEW:** you land on the SPA. Click **Sign in with Microsoft**.
3. MSAL popup → Entra login. **If a consent screen appears**, that's the `access_as_user` scope being granted to the SPA. Click Accept.
4. Popup closes. Back on the SPA, you now see a text input.
5. Type "hello" → click Send.
6. ~2-5 seconds later: a reply from gpt-4o appears.

**That's the win.** Try a follow-up: "Give me three bullet points on why workload identity beats API keys."

---

## 6. Verify what happened (security engineer side)

**What this does:** inspects the actual chain that fired.

```bash
# n8n executed the workflow
kubectl logs -n n8n deploy/n8n --tail=20 | grep -iE "workflow|webhook"

# oauth2-proxy validated your bearer (look for the X-Auth-Request-User header)
kubectl logs -n n8n deploy/oauth2-proxy --tail=20

# Defender for AI will eventually surface the prompt under your OID. Until
# Phase 3 enables Defender for AI, just verify AOAI saw the request:
az monitor metrics list \
  --resource $(az cognitiveservices account show -g rg-dsolab-sea -n aoai-dsolab-aue --query id -o tsv) \
  --metric "ProcessedPromptTokens" \
  --interval PT5M \
  --query "value[0].timeseries[0].data[-3:]" -o table
```

---

## 7. Commit + open PR

```bash
git status
git add .
git commit -m "feat(1ed): SPA + n8n -> AOAI workflow (Phase 1 done)"
git push -u origin feat/10-spa-and-aoai
gh pr create --fill --title "feat/10: Phase 1E-d — SPA + AOAI (Phase 1 done)"
```

Merge:

```bash
gh pr merge --squash --delete-branch
```

---

## 8. Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| MSAL popup: `AADSTS65001: consent required` | Tenant disabled user consent for the scope | Admin grants consent: `az ad app permission admin-consent --id <SPA_APP_ID>` |
| MSAL popup: `AADSTS50011: redirect_uri mismatch` | SPA app reg doesn't have the prod URI | Re-run `scripts/08-build-and-push-spa.sh` — it adds the URI |
| SPA loads, Sign In works, but fetch returns 401 | oauth2-proxy didn't pick up the JWT config | `kubectl logs -n n8n deploy/oauth2-proxy` and check for `extra-jwt-issuers` in startup args; re-run `scripts/09-deploy-spa-and-workflow.sh` |
| fetch returns 502 from /webhook/chat | n8n webhook URL doesn't include `/webhook/chat`. n8n requires the workflow to be **active** | Re-run import Job, or open n8n UI and toggle workflow Active on top right |
| n8n workflow runs but Get AOAI Token errors: `Missing AZURE_TENANT_ID/AZURE_CLIENT_ID` | Workload identity webhook not labeling this pod | Verify `kubectl get sa n8n -n n8n -o yaml` has `azure.workload.identity/use: "true"` label; check Deployment pod template also has it |
| AOAI call returns 403 `PermissionDenied` | MI doesn't have the role on AOAI | Verify `az role assignment list --scope <AOAI-id> --query "[?roleDefinitionName=='Cognitive Services OpenAI User']" -o table` shows the n8n MI |
| AOAI call returns 401 `InvalidAuthenticationToken` | Federated token exchange failed silently | Read Code node's full error in n8n's Execution log; usually means `client_credentials` body has a bad parameter or the FIC isn't configured |
| Reply comes back but is empty | gpt-4o quota / safety filter | Check Defender for Cloud → AI workload protection alerts (Phase 5) |
| Import Job fails: `unable to connect to database` | n8n CLI uses different env vars than the n8n pod | Job's envFrom should be the same `n8n-secrets` Secret; check `kubectl describe job -n n8n import-chat-workflow` |
| Import Job fails: `encryption key mismatch` | `N8N_ENCRYPTION_KEY` in the Secret differs from what's stored in n8n's DB | Re-run `scripts/04-postgres-init.sh` to rotate, then `scripts/05-deploy-n8n.sh` + `scripts/09-deploy-spa-and-workflow.sh` |

---

## 9. What we deliberately did NOT do (yet)

| To | What |
|---|---|
| **Phase 2** | GHAS code scanning, Defender CLI scan on the SPA image, dependency review for the SPA |
| **Phase 3** | Flip LE staging → LE prod (trusted cert); restrict oauth2-proxy `--email-domain=*` to your tenant domain; admission control / OPA policies |
| **Phase 4** | AI SPM — Defender for AI workload protection. The `user:` field we pass to AOAI is what attributes prompts to a real user in their alerts |
| **Phase 5** | CVE-2025-68613 detonation — try to make n8n execute attacker-controlled JS via a malicious workflow trigger |
| **Phase 6** | Sentinel + MSEM correlation across audit trails |

---

## 10. Cost note

- SPA image storage in ACR: a few MB → negligible (~$0.01/mo)
- AOAI: pay-per-token. A few demo conversations: $0.05-$0.20 total
- No new compute

That's it. **Phase 1 — secure-by-construction SPA + agent platform on AKS with zero API keys — is done.**
