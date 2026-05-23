# Runbook — Phase 1E-c: Real URL with HTTPS + Entra login

> **Goal:** kill `kubectl port-forward`. Replace it with a real URL like
> `https://chat.20.195.16.7.nip.io/` that has TLS (Let's Encrypt staging)
> and requires Entra ID sign-in before any request reaches n8n.
>
> **Win:** open the URL in a fresh browser, get redirected to Microsoft
> login, sign in, then land on n8n.

---

## 0. What this PR adds

| File | Purpose |
|---|---|
| `k8s/oauth2-proxy/deployment.yaml` | oauth2-proxy v7.7.1 in reverse-proxy mode, OIDC against Entra |
| `k8s/oauth2-proxy/service.yaml` | Internal ClusterIP `:4180` |
| `k8s/n8n/ingress.yaml` | NGINX Ingress with cert-manager annotation; routes ALL traffic to oauth2-proxy (not n8n directly) |
| `k8s/n8n/deployment.yaml` (modified) | Reads `N8N_HOST/N8N_PROTOCOL/WEBHOOK_URL` from a new `n8n-config` ConfigMap |
| `scripts/06-create-oauth2-proxy-app.sh` | Creates Entra app reg `oauth2-proxy-dsolab` (Web platform, redirect URI, client secret) |
| `scripts/07-deploy-oauth2-proxy.sh` | Fetches KV secrets → K8s Secrets/ConfigMap → applies manifests → waits for cert |
| `docs/runbook-phase-1e-c.md` | This file |

No Terraform changes.

---

## 1. Mental model

```
Internet  ─► 20.195.16.7:443  ─► NGINX Ingress (terminates TLS)
                                       │
                                       ▼
                                 oauth2-proxy:4180
                                  │           │
                  not signed in   │           │  signed in
                                  ▼           ▼
                         Microsoft Entra    n8n.n8n.svc:5678
                              (login)
```

**Two auth layers on purpose:**
1. **oauth2-proxy** — gates *who can even reach n8n* (any user with an Entra account in your tenant). This is the "front door bouncer."
2. **n8n owner login** — n8n's internal user system that you set up in 1E-b. This is the "second factor" for n8n-specific permissions (admin vs. member).

In real production you'd want one of:
- Disable n8n auth and trust oauth2-proxy completely (`N8N_USER_MANAGEMENT_DISABLED=true`)
- Or use n8n's SSO feature to chain Entra → n8n identity

For the lab we keep both — it makes a great "defense in depth" demo for security reviews.

---

## 2. Run the app-registration script

**What this does:** creates a new Entra app reg `oauth2-proxy-dsolab` (separate from your SPA + n8n-api app regs — different role, different platform type). Generates a client secret valid 24 months. Stores app ID + secret + cookie secret in Key Vault.

```bash
cd ~/Desktop/DevSecOps-True
./scripts/06-create-oauth2-proxy-app.sh
```

The script auto-detects your ingress IP and computes the FQDN. It registers `https://chat.<ip>.nip.io/oauth2/callback` as the redirect URI.

**Verify the app reg + secrets:**

```bash
KV=$(az keyvault list -g rg-dsolab-sea --query "[0].name" -o tsv)
az keyvault secret list --vault-name "$KV" --query "[?starts_with(name, 'oauth2-proxy')].name" -o tsv
```

Expected:

```text
oauth2-proxy-client-id
oauth2-proxy-client-secret
oauth2-proxy-cookie-secret
```

---

## 3. Deploy oauth2-proxy + Ingress

**What this does:** the deploy script does 7 things end-to-end:
1. Reads the secrets you just created
2. Creates `oauth2-proxy-secrets` K8s Secret
3. Creates `n8n-config` ConfigMap with your real public URL
4. Applies oauth2-proxy Deployment + Service
5. Renders & applies the Ingress (substitutes `${INGRESS_HOST}`)
6. Restarts n8n so it picks up the new hostname
7. Waits up to 5 min for cert-manager to issue the LE-staging certificate

```bash
./scripts/07-deploy-oauth2-proxy.sh
```

Watch for `✓ Certificate Ready`. If it doesn't go Ready in 5 min, the script prints diagnostic commands.

---

## 4. Test it

### 4a. Browser — the real test

**What this does:** open the public URL. First time you'll see two things:
1. **Browser security warning** — "Your connection is not private". That's correct for **Let's Encrypt staging certs** (they're untrusted by design). Click **Advanced → Proceed**. Phase 3 swaps to LE prod for trusted certs.
2. **Microsoft login screen** — sign in with the Entra account you'd normally use. (Any account in your tenant works; restrict later if you want.)
3. **n8n login** — your own n8n owner credentials from 1E-b.

Open: **`https://chat.<your-ingress-ip>.nip.io/`** (replace IP).

### 4b. Inspect cert details

**What this does:** prints the TLS cert details. Issuer should be Let's Encrypt staging (`STAGING Let's Encrypt`). Hostname should match.

```bash
PUBLIC_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo | openssl s_client -showcerts -connect "chat.${PUBLIC_IP}.nip.io:443" -servername "chat.${PUBLIC_IP}.nip.io" 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Expected something like:

```text
subject=CN=chat.20.195.16.7.nip.io
issuer=C=US, O=(STAGING) Let's Encrypt, CN=(STAGING) Pretend Pear X1
notBefore=May 23 ...
notAfter=Aug 21 ...
```

### 4c. Check oauth2-proxy's auth headers

**What this does:** when you're inside n8n's editor, open browser DevTools → Network. Any XHR will show `Cookie: _oauth2_proxy=...` and `X-Forwarded-Access-Token: eyJ0...` headers. Those headers prove the auth gate is working.

---

## 5. Commit + open PR

```bash
git status
git add .
git commit -m "feat(1ec): oauth2-proxy + Ingress + TLS"
git push -u origin feat/08-oauth2-proxy-ingress
gh pr create --fill --title "feat/08: Phase 1E-c — oauth2-proxy + Ingress + TLS"
```

After merge:

```bash
gh pr merge --squash --delete-branch
```

---

## 6. Deliberately deferred

| To | What |
|---|---|
| **1E-d** | SPA + n8n workflow that actually calls Azure OpenAI; end-to-end browser → SPA → n8n → AOAI |
| **Phase 3** | Flip ClusterIssuer to `letsencrypt-prod` (trusted certs); restrict `--email-domain=*` to your tenant; add admission control / OPA policies |
| **Phase 4** | Single-sign-on between oauth2-proxy → n8n (so users don't see n8n's own login) |

---

## 7. Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| Browser shows "AADSTS50011: redirect_uri mismatch" | Redirect URI on the app reg doesn't match the URL being used | Re-run `06-create-oauth2-proxy-app.sh` — it auto-detects current IP |
| Browser stuck in redirect loop after login | `cookie-secure=true` but you're on http (no TLS) | Check cert-manager: `kubectl get cert -n n8n n8n-tls`. If not Ready, the ingress is still serving plain HTTP via the LE challenge path |
| Cert stuck `READY=False` for >5 min | LE HTTP-01 challenge can't reach the cluster | `kubectl describe challenge -n n8n` — common cause: Defender CSPM disabled `publicNetworkAccess` on something. Check ingress is publicly reachable: `curl http://chat.<ip>.nip.io/.well-known/acme-challenge/test` should return 404 (not connection refused) |
| n8n editor websockets fail after login (charts not updating) | `N8N_PROXY_HOPS` not set | Check `kubectl describe deploy/n8n -n n8n` shows `N8N_PROXY_HOPS=1` from the ConfigMap; if not, re-run script 07 |
| "Sign in with Microsoft" page never shows my account | Tenant has Conditional Access blocking the new app reg | Check Entra → Sign-in logs for your user → look for failed sign-ins to `oauth2-proxy-dsolab` |
| oauth2-proxy CrashLoopBackOff with `invalid cookie secret` | Cookie secret isn't 16/24/32 bytes after base64-decode | Re-run `06-create-oauth2-proxy-app.sh` (it generates the right length) |

---

## 8. Cost note

Zero new Azure resources. oauth2-proxy is ~30 MiB, fits easily on existing nodes. LE staging certs are free.
