# ADR 0005 — Use `nip.io` for the lab FQDN

**Status**: Accepted
**Date**: 2026-05-22
**Phase**: 1A (consumed by Phase 1E ingress)

## Context

The SPA + n8n need a public HTTPS FQDN so users can access the chat UI and Entra can redirect back after sign-in (MSAL redirect URIs must be HTTPS for non-localhost). Three options:

1. **`nip.io`** — wildcard DNS that resolves `<anything>.<ip>.nip.io` to `<ip>`. Free, no DNS to manage. Let's Encrypt issues certs to `nip.io` subdomains (subject to global rate limits but fine for lab scale).
2. **Existing Azure DNS zone** the user owns.
3. **Buy a cheap domain** ($1–12/yr).

## Decision

Use **`nip.io`** for the lab FQDN.

The chat URL will look like: `https://chat.<ingress-loadbalancer-ip>.nip.io/` where `<ingress-loadbalancer-ip>` is the public IP of the NGINX Ingress Controller's LoadBalancer service (set in Phase 1E).

## Why nip.io

- **Zero setup, zero cost**. Works the moment the AKS LoadBalancer gets a public IP.
- **Real Let's Encrypt certificates work**. `nip.io` is a well-known free service; LE issues real certs for its subdomains (with the standard ACME rate limit of 50 certs/week per registered domain — well under the lab's needs).
- **Avoids domain ownership coupling**: the lab is reproducible by anyone — no "you need to own example.com" prerequisite.
- **Entra MSAL redirect URIs accept it**: as long as the URI is HTTPS, Entra doesn't care about the domain.

## Tradeoffs

- **URL is ugly**: `chat.20-1-2-3.nip.io` is not memorable. Fine for a lab; would be unacceptable for production.
- **IP-coupled**: if the AKS LoadBalancer IP changes (e.g., cluster rebuild), the FQDN changes, and you must update:
  - Entra SPA app reg redirect URIs
  - oauth2-proxy `--redirect-url`
  - cert-manager Certificate (auto re-issues, but the old cert is orphaned)
  - The Phase 1F smoke test screenshots
  
  Mitigation: in Terraform, assign a **static public IP** to the LoadBalancer (separate `azurerm_public_ip` resource, then `service.beta.kubernetes.io/azure-load-balancer-ipv4` annotation on the Service). Done in Phase 1E.
- **Initial cert issuance from Let's Encrypt staging vs production**: start with staging issuer (which gives untrusted certs, browser warns) to avoid burning LE prod rate limits during cluster setup iteration; switch to prod issuer once the rest of the stack is stable.

## When to reconsider

If you want to demo this lab to others, or you'd like a clean URL, swap to options 2 or 3. Code changes are limited to:
- `terraform/modules/ingress/` (DNS record creation)
- `terraform/modules/entra-apps/` (SPA redirect URI)
- The cert-manager `Issuer` resource (if changing email)
