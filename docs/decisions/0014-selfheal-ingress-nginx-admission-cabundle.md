# ADR 0014: Self-heal `ingress-nginx-admission` webhook caBundle in script 07

- **Status**: Accepted
- **Date**: 2026-05-23
- **Phase**: 1E-c (discovered during first deploy)

## Context

`scripts/03-cluster-prereqs.sh` installs ingress-nginx via Helm
(`helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx ...`).
The chart ships a `ValidatingWebhookConfiguration` named
`ingress-nginx-admission` that gatekeeps every `Ingress` create/update.

For TLS between kube-apiserver and the admission webhook to work, the
ValidatingWebhookConfiguration's `clientConfig.caBundle` must contain the CA
that signed the cert in the `ingress-nginx-admission` Secret. The chart
provides a post-install Job (`ingress-nginx-admission-create` +
`ingress-nginx-admission-patch`) that generates the cert/CA and patches the
webhook.

That Job is hooked into Helm's `post-install,post-upgrade` lifecycle. **But**
if the chart has already been installed and a subsequent `helm upgrade`
fails (e.g., our 1E-a `--reuse-values` failure that left the release in a
weird state), the patch hook may not re-execute. The webhook ends up with an
empty `caBundle`, and every `Ingress` create fails with:

```text
Error from server (InternalError): error when creating "STDIN":
  Internal error occurred: failed calling webhook "validate.nginx.ingress.kubernetes.io":
  failed to call webhook: Post "https://...:443/...":
  tls: failed to verify certificate: x509: certificate signed by unknown authority
```

We hit this exact symptom in 1E-c. Patching the webhook with the CA from
the existing Secret is safe, idempotent, and resolves it immediately:

```bash
CA=$(kubectl get secret -n ingress-nginx ingress-nginx-admission -o jsonpath='{.data.ca}')
kubectl patch validatingwebhookconfiguration ingress-nginx-admission \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/webhooks/0/clientConfig/caBundle\",\"value\":\"$CA\"}]"
```

## Decision

`scripts/07-deploy-oauth2-proxy.sh` runs a pre-flight check (`[0/7]`):

1. Read the current `caBundle` from the webhook config.
2. If empty, fetch the CA from the `ingress-nginx-admission` Secret and
   patch the webhook.
3. Otherwise, no-op.

This makes the script robust against a state where someone's cluster has
been Helm-upgraded in a way that left the webhook un-patched. It does not
hide the root cause — the script logs a message saying it patched the bundle
— so the user knows their cluster state needed repair.

## Alternatives considered

1. **Re-install ingress-nginx from scratch.** Wipes the public IP, requires
   re-registering nip.io URLs everywhere, breaks any in-flight n8n sessions.
   Way too disruptive for a one-line fix.

2. **Run `helm upgrade --force` on ingress-nginx.** May re-trigger the patch
   Job, but also re-rolls the controller (downtime) and risks the same
   `--reuse-values` issue we saw in ADR 0011. Heavier than needed.

3. **Disable the validating webhook entirely** (`controller.admissionWebhooks.enabled=false`).
   Loses pre-create validation of Ingress objects, which catches genuine
   mistakes (e.g., conflicting hostnames). Bad trade for a lab that demos
   security.

4. **Fix it upstream in `scripts/03-cluster-prereqs.sh` instead.**
   Already considered: the post-install hook *runs* correctly on the first
   `helm install`. The failure mode only manifests after a *failed upgrade*.
   Putting the self-heal in script 07 (the first script that depends on a
   working admission webhook) catches the symptom at the right layer.

## Consequences

**Positive:**

- `scripts/07-deploy-oauth2-proxy.sh` succeeds first-try on a cluster whose
  webhook is broken.
- The log message ("caBundle empty — patching ...") makes the issue
  discoverable; the user knows their cluster needed repair.

**Negative:**

- Adds 3 `kubectl` calls to a script that doesn't otherwise touch the
  ingress-nginx namespace. Slight separation-of-concerns smell.

## Verification

```bash
# After installer fix or self-heal:
WEBHOOK_CA=$(kubectl get validatingwebhookconfiguration ingress-nginx-admission \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}')
SECRET_CA=$(kubectl get secret -n ingress-nginx ingress-nginx-admission \
  -o jsonpath='{.data.ca}')
[ "$WEBHOOK_CA" = "$SECRET_CA" ] && echo OK || echo MISMATCH

# Then any Ingress create should succeed:
kubectl get ingress -n n8n
# Expect: n8n  chat.<ip>.nip.io  20.195.16.7  80,443
```

## Related

- ADR 0011 — NGINX single-replica + Local traffic policy (the failed
  `helm upgrade --reuse-values` from there is the proximate cause).
- ADR 0012 / 0013 — also Defender / cluster-state-induced issues we
  self-heal around.
