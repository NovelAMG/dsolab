# Runbook — Phase 1E-b: Deploy n8n on AKS

> **Goal:** an n8n pod running on the cluster, connected to Postgres, persisting
> workflows to an Azure Files share. No ingress, no auth yet (1E-c) — we verify
> with `kubectl port-forward` and open n8n's setup wizard in the browser.
>
> **Win:** browser shows the n8n owner-setup screen at `http://localhost:5678`.

---

## 0. What this PR adds

| File | Purpose |
|---|---|
| `k8s/n8n/pvc.yaml` | 5 GiB Azure Files PVC for n8n binary data |
| `k8s/n8n/service.yaml` | Internal ClusterIP on port 5678 |
| `k8s/n8n/deployment.yaml` | n8n Deployment — single replica, B2s-sized, uses workload-identity SA |
| `k8s/n8n/init-job.yaml` | One-shot Job (postgres:16-alpine) that creates the n8n DB + role |
| `scripts/04-postgres-init.sh` | Generates passwords, stores them in KV, runs the init Job |
| `scripts/05-deploy-n8n.sh` | Fetches KV secrets, applies manifests, waits for Ready |
| `docs/runbook-phase-1e-b.md` | This file |

No Terraform changes. Postgres firewall already allows AKS via `AllowAllAzureServices`.

---

## 1. Run the Postgres init script

**What this does:** populates Postgres with what n8n needs.
- Reads the admin password from Key Vault (so you never see it)
- Generates a strong random password for the **`n8n`** database role
- Generates a random 32-byte encryption key (n8n uses this internally to encrypt stored credentials in its DB; losing it means losing every saved credential)
- Stores both new secrets in Key Vault
- Submits a K8s Job that runs `psql` from inside the cluster to create the DB + role

> Inline-from-cluster psql is cleaner than installing psql on your laptop and futzing with temp firewall rules.

```bash
cd ~/Desktop/DevSecOps-True
./scripts/04-postgres-init.sh
```

Expect output ending with:

```text
Job logs:
    >>> Connecting to Postgres as admin
    >>> Creating database n8n owned by n8n
    >>> Done. n8n role + database ready.
```

**Verify the new KV secrets exist:**

**What this does:** lists secrets in Key Vault to confirm the script saved them.

```bash
KV=$(az keyvault list -g rg-dsolab-sea --query "[0].name" -o tsv)
az keyvault secret list --vault-name "$KV" --query "[?contains(name, 'n8n')].name" -o tsv
```

Expected:

```text
n8n-db-password
n8n-encryption-key
```

---

## 2. Deploy n8n

**What this does:** the deploy script:
- Fetches the secrets you just stored
- Creates a K8s Secret `n8n-secrets` (the Deployment reads this via `envFrom`)
- Applies the PVC → Service → Deployment in that order
- Triggers a rollout restart (so any rotated secret is picked up)
- Waits up to 5 min for the pod to become Ready (B2s is slow at first boot)

```bash
./scripts/05-deploy-n8n.sh
```

Expect the script to finish with `deployment "n8n" successfully rolled out` and a summary of pods/svc/pvc.

If it times out, the script prints recent events + the pod's logs automatically. Most common failure: image pull slow on B2s. Re-running is safe.

---

## 3. Verify

### 3a. Pod is Ready

**What this does:** lists pods in the `n8n` namespace; `1/1 Ready` means n8n is up.

```bash
kubectl get pods -n n8n
```

Expected:

```text
NAME                    READY   STATUS    RESTARTS   AGE
n8n-xxxxxxxxx-xxxxx     1/1     Running   0          2m
```

### 3b. n8n is healthy from inside the cluster

**What this does:** runs an ephemeral curl pod in the cluster and hits n8n's internal `/healthz`. Confirms the Service → Pod path works before we bother with port-forward.

```bash
kubectl run curl-test -n n8n --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://n8n:5678/healthz
```

Expected:

```text
{"status":"ok"}
```

### 3c. Workload-identity env was auto-injected

**What this does:** prints the AZURE_* env vars on the running pod. These come from the Workload Identity webhook — proof that 1E-a's wiring works. We don't USE them yet, but seeing them confirms 1E-d will be a config-only step.

```bash
kubectl exec -n n8n deploy/n8n -- env | grep ^AZURE_
```

Expected (values will match your tenant + n8n MI):

```text
AZURE_CLIENT_ID=470f3d1d-09b4-4837-9d6e-712729379312
AZURE_TENANT_ID=b676efda-5e5b-43d3-893e-4ed357b457c4
AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
```

### 3d. Open n8n in your browser

**What this does:** `kubectl port-forward` opens a tunnel from a local port on your laptop to the K8s Service inside the cluster. Traffic to `localhost:5678` is forwarded to `svc/n8n:5678` → the n8n pod. **The tunnel only exists while this command runs** — kill it with Ctrl-C when done. This is for debugging; real users will reach n8n via the Ingress we add in 1E-c.

```bash
kubectl port-forward -n n8n svc/n8n 5678:5678
```

Open **<http://localhost:5678>** in your browser. You should see n8n's **setup wizard** asking you to create an owner account. **Fill it in** — your email/password is stored only in n8n's Postgres DB.

After clicking through the wizard you should land on an empty n8n canvas. That's the win.

---

## 4. Commit + open PR

**What this does:** standard "save and review" flow.

```bash
git status
git add .
git commit -m "feat(1eb): n8n deployment + postgres init"
git push -u origin feat/06-n8n-deploy
gh pr create --fill --title "feat/06: Phase 1E-b — n8n on AKS"
```

Then merge:

```bash
gh pr merge --squash --delete-branch
```

(No CI infra checks here — `tf-plan` will run and show 0 changes, since this PR is pure K8s/scripts.)

---

## 5. What we deliberately did NOT do

| Deferred to | Item |
|---|---|
| **1E-c** | NGINX Ingress rule + cert-manager Certificate + oauth2-proxy for n8n; replaces port-forward with `https://chat.<ip>.nip.io/` |
| **1E-d** | n8n workflow that actually calls Azure OpenAI using the auto-injected workload-identity token. SPA built + pushed to ACR. End-to-end browser-to-AOAI path. |
| **Phase 3** | Postgres password rotation via CSI Secret Store driver (instead of one-shot KV copy); Postgres CA bundle mount to flip `DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED` to `true`; n8n image to private mirror in ACR. |

---

## 6. Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| init job fails: `password authentication failed` | The `postgres-admin-password` KV secret is stale (e.g., TF re-ran and rotated it) | Re-run `04-postgres-init.sh` — it reads the current KV value |
| init job fails: `Could not connect to server` | Postgres firewall changed (someone toggled `AllowAllAzureServices` off) | `az postgres flexible-server firewall-rule create --rule-name AllowAllAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -g rg-dsolab-sea -n psql-dsolab-sea-xsqb` |
| n8n pod CrashLoopBackOff with `ECONNREFUSED ::1:5432` | DB env vars not set (Secret missing or typo'd) | `kubectl describe pod -n n8n -l app=n8n` and check `Environment From` lists `n8n-secrets`; if not, re-run `05-deploy-n8n.sh` |
| Pod stuck `Pending` with `pod has unbound PersistentVolumeClaims` | Azure Files PVC provisioning takes 60-90s on first attach | Wait, then `kubectl describe pvc -n n8n n8n-data` |
| Pod runs but health probe fails | First-boot DB migration is slow on B2s (~30-60s) | `startupProbe` already gives 3 min; if still failing, check `kubectl logs -n n8n deploy/n8n` for migration errors |
| Browser shows "Setup new owner account" but submit fails silently | n8n encryption key mismatch (changed between Secret creation + pod start) | Delete the pod, the new one picks up current Secret: `kubectl delete pod -n n8n -l app=n8n` |

---

## 7. Cost note

This phase adds:
- **5 GiB Azure Files** (Standard LRS): ~$0.30/mo
- **No new compute** (n8n runs on existing AKS nodes)

To delete everything: `kubectl delete ns n8n` (also wipes the PVC → triggers Azure Files share deletion via dynamic provisioning). The Postgres `n8n` database stays unless you drop it manually.
