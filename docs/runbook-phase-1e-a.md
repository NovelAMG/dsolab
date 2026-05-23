# Runbook — Phase 1E-a: Cluster prerequisites

> **Goal of this phase:** make the AKS cluster ready to host the n8n stack by
> installing the things that come *before* n8n: an ingress controller (public
> entry point), cert-manager (TLS), and the n8n namespace + ServiceAccount that
> Phase 1D's workload identity is federated to.
>
> **The win at the end:** you visit `http://<public-ip>/` in your browser and
> see NGINX's default 404 page. That 404 is good — it proves traffic reaches
> the cluster. We add real apps in 1E-b.

---

## 0. What this PR contains

| File | Why |
|---|---|
| `bigpicture.html` (updated) | Adds **Dev workflow cheatsheet** — a glossary for the commands below |
| `docs/decisions/0010-blob-data-role-at-storage-account-scope.md` | ADR: captures yesterday's silent fix |
| `scripts/00-bootstrap-state.sh` (patched) | Grants `Storage Blob Data Contributor` at SA scope (was container-only) |
| `scripts/03-cluster-prereqs.sh` (new) | Installs NGINX, cert-manager, LE staging issuer, n8n ns/SA |
| `docs/runbook-phase-1e-a.md` (this file) | The runbook you're reading |

No Terraform changes in this PR — the `AcrPull` role was already in the AKS module from Phase 1B. We're working at the K8s layer now.

---

## 1. Prereqs on your laptop

You need three CLIs. Install whatever's missing:

**What this does:** installs Kubernetes CLI (`kubectl`) and Helm (Kubernetes package manager). `az` you already have.

```bash
# Brew is macOS's package manager — like apt-get on Ubuntu.
brew install kubernetes-cli helm
```

**Verify:**

```bash
# Each should print a version. If "command not found" — Brew didn't install it.
kubectl version --client
helm version
az version
```

---

## 2. Point kubectl at our AKS cluster

**What this does:** writes an entry into `~/.kube/config` so `kubectl` knows *which* cluster to talk to and *who you are*. After this, every `kubectl` command runs against `aks-dsolab-sea`.

> `--overwrite-existing` is safe here — it just replaces any stale entry from a previous `get-credentials` run.

```bash
az aks get-credentials \
  -g rg-dsolab-sea \
  -n aks-dsolab-sea \
  --overwrite-existing
```

**Verify cluster is up and you can reach it:**

**What this does:** lists the worker VMs. We expect 2, both `Ready`. If you see "stopped" — run `az aks start -g rg-dsolab-sea -n aks-dsolab-sea` first.

```bash
kubectl get nodes
```

Expected output:

```text
NAME                              STATUS   ROLES    AGE   VERSION
aks-system-xxxxxxxx-vmss000000    Ready    <none>   2d    v1.34.7
aks-system-xxxxxxxx-vmss000001    Ready    <none>   2d    v1.34.7
```

---

## 3. Run the cluster-prereqs installer

**What this does:** runs the idempotent script that installs NGINX Ingress, cert-manager, the LE staging issuer, and the n8n namespace + ServiceAccount. The `LE_EMAIL=` part sets an env var *just for this command* — Let's Encrypt requires an email for cert expiry notifications.

> Use a real email you check. Staging certs are fake-trusted so you won't get spammed, but if you flip to prod later this is the one LE uses.

```bash
cd ~/Desktop/DevSecOps-True
LE_EMAIL=you@example.com ./scripts/03-cluster-prereqs.sh
```

The script will print a summary and ask `Proceed? (y/N)`. Type `y`.

It takes ~3 minutes. The slow parts are:
- Helm waiting for NGINX pods to become Ready (~60s)
- Azure provisioning the public Load Balancer behind the NGINX Service (~60s, happens in background)
- Helm waiting for cert-manager webhook to become Ready (~60s)

---

## 4. Verify everything

### 4a. NGINX got a public IP

**What this does:** asks for the public IP that the Azure Load Balancer provisioned for the NGINX Service. The `-o jsonpath=...` syntax extracts just one field from the JSON response — same idea as `az --query`. If this prints empty for the first ~30s, just wait and re-run — the LB is still being created.

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'
```

Expected: a public IPv4 like `20.198.x.x`. **Save this** — you'll use it in 1E-b for the nip.io FQDN.

### 4b. cert-manager pods are healthy

**What this does:** lists pods in the `cert-manager` namespace. We expect three pods (`cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector`), all `Running` with `1/1` ready. If any are `CrashLoopBackOff`, run `kubectl logs -n cert-manager <pod-name>` to see why.

```bash
kubectl get pods -n cert-manager
```

### 4c. ClusterIssuer is ready

**What this does:** checks the Let's Encrypt staging issuer is registered with LE. `READY=True` means cert-manager successfully reached LE and registered an ACME account. `READY=False` usually means egress firewall is blocking `acme-staging-v02.api.letsencrypt.org` — not an issue on default AKS.

```bash
kubectl get clusterissuer letsencrypt-staging
```

Expected:

```text
NAME                  READY   AGE
letsencrypt-staging   True    1m
```

### 4d. n8n ServiceAccount is wired to the MI

**What this does:** prints the full ServiceAccount YAML so we can eyeball the annotations. The two things we MUST see: `azure.workload.identity/client-id` (must match your MI's clientId `470f3d1d-09b4-4837-9d6e-712729379312`) and the label `azure.workload.identity/use: "true"` at the SA level (so the webhook picks up pods using it).

```bash
kubectl get sa n8n -n n8n -o yaml
```

### 4e. Visit the IP in your browser

**What this does:** the win condition. Browser hits the LB → NGINX gets the request → no Ingress resource matches → NGINX returns its default 404. That 404 means everything from "DNS / TCP / TLS handshake / HTTP routing" works end-to-end.

```bash
PUBLIC_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Open in browser: http://$PUBLIC_IP/"
```

You should see:

```text
404 Not Found
nginx
```

---

## 5. Commit + open the PR

**What this does:** the standard git "save my changes and ask for a review" flow.
1. `git status` — see what's changed in the working tree (read-only sanity check).
2. `git add .` — stage everything in the current dir and below.
3. `git commit -m "..."` — snapshot it with a message describing *why*.
4. `git push -u origin <branch>` — upload the branch to GitHub (`-u` remembers this so future `git push` is enough).
5. `gh pr create --fill` — open a PR using the commit message as the body.

```bash
cd ~/Desktop/DevSecOps-True
git status

git add .
git commit -m "feat(1ea): cluster prereqs — nginx + cert-manager + n8n ns/SA, ADR 0010"
git push -u origin feat/04-cluster-prereqs

gh pr create --fill --title "feat/04: Phase 1E-a — cluster prereqs"
```

The `tf-plan` workflow will run on this PR. It should show **0 changes** — this PR doesn't touch Terraform-managed infra.

### Merge when green

**What this does:** squashes all your commits into one tidy commit on `main`, then deletes the feature branch (locally and on GitHub).

```bash
gh pr merge --squash --delete-branch
```

---

## 6. What we did NOT do (so you know what's still ahead)

| Deferred to | Item |
|---|---|
| **1E-b** | Postgres user/DB init for n8n, K8s Secret with n8n encryption key, n8n Deployment + Service, PVC on Azure Files |
| **1E-c** | oauth2-proxy in JWT mode validating SPA bearer tokens; Ingress rules for `/api/` and `/webhook/` |
| **1E-d** | SPA (Vite + React + MSAL.js), Dockerfile, ACR push, deploy workflow; SPA app reg redirect URI update for the prod URL |
| **Phase 3** | Switch ClusterIssuer from `letsencrypt-staging` → `letsencrypt-prod` (after admission control + network policies are in place) |
| **Phase 3** | Private endpoints for KV/SA — would remove the recurring "public network access auto-disable" issue at the root |

---

## 7. Common gotchas

| Symptom | Likely cause | Fix |
|---|---|---|
| `kubectl get nodes` hangs | AKS is stopped | `az aks start -g rg-dsolab-sea -n aks-dsolab-sea` then flush DNS: `sudo dscacheutil -flushcache` |
| Script fails at "ERROR: managed identity not found" | Phase 1D never applied | Check the merged PRs, re-run tf-apply |
| LB IP is `<pending>` for >5 min | Azure quota or NSG block | `kubectl describe svc -n ingress-nginx ingress-nginx-controller` and check events |
| Browser shows `ERR_CONNECTION_REFUSED` | NGINX pods CrashLoopBackOff | `kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50` |
| cert-manager webhook timeout on install | First-install race — webhook not ready when CRDs are first registered | Re-run the script. It's idempotent. |

---

## 8. Cost note

This phase adds **one Azure Public Load Balancer + one Public IP**. Combined cost: ~$4/mo (standard SKU LB) + free tier for the IP. The LB itself is created by Kubernetes the moment NGINX's Service is `type: LoadBalancer`. To delete: `helm uninstall ingress-nginx -n ingress-nginx`.
