# ADR 0014: n8n Code-node vm2 sandbox quirks (process.env, URLSearchParams, require)

- **Status**: Accepted
- **Date**: 2026-05-23
- **Phase**: 1E-d (discovered while wiring the AOAI-token Code node)

## Context

The Phase 1E chat workflow uses a single n8n **Code** node ("Get AOAI Token
(WL identity)") to:

1. Read the projected federated SA token from
   `/var/run/secrets/azure/tokens/azure-identity-token`.
2. POST it to Entra's `/oauth2/v2.0/token` as a `client_assertion` with
   grant type `client_credentials` and scope
   `https://cognitiveservices.azure.com/.default`.
3. Pass the resulting AOAI access token to the next node (HTTP Request →
   `gpt-4o`).

n8n Code nodes run in **vm2** — a hardened sandbox that hides a surprising
amount of the standard Node runtime. We hit this three times in a row
while writing 30 lines of JavaScript:

| Standard Node feature | vm2 behaviour | Workaround |
|---|---|---|
| `require('fs')` | `VMError: Cannot find module 'fs'` | Set `NODE_FUNCTION_ALLOW_BUILTIN=*` on the n8n pod |
| `process.env.X` | `undefined` (no error) | Use `$env.X` — n8n's curated env accessor |
| `new URLSearchParams({...})` | `ReferenceError: URLSearchParams is not defined` | Hand-encode with `encodeURIComponent` |

Each one cost a debug round-trip through the chat UI → Executions tab →
fix → save → resend message → next error. They are individually trivial
and collectively the kind of friction that makes "just write a small
script in n8n" deceptively expensive.

## Decision

1. **Allow all Node built-ins** in Code nodes by setting
   `NODE_FUNCTION_ALLOW_BUILTIN=*` (not just `fs`) on the n8n Deployment.
   The blast radius is contained to a single namespace and a single pod
   running a single tenant's workflows. We accept the trade-off in
   exchange for "imports just work" in future Code nodes (crypto, path,
   url, …).
2. **Always use `$env.X`**, never `process.env.X`, in Code nodes. The
   workflow JSON committed to git uses this convention.
3. **Never use `URLSearchParams`** in Code nodes. Hand-encode form bodies
   with `encodeURIComponent`. (Same applies to other Web-platform globals
   that vm2 may not expose: `fetch`, `URL`, `crypto.subtle`, etc. — when
   in doubt, use `this.helpers.httpRequest` and Node built-ins.)

## Alternatives considered

1. **Move the token exchange out of n8n** into a sidecar or a small Go
   binary inside the n8n pod. Cleaner code, but adds a moving piece and
   defeats the "n8n as DevSecOps automation hub" demo goal.
2. **Disable vm2 entirely** via `N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=false`
   and similar flags. n8n still uses vm2 for Code nodes regardless;
   there's no first-class "trust me, run raw Node" toggle in OSS n8n.
3. **Use the Function Item node instead of Code.** Same sandbox, same
   quirks — no gain.
4. **Allow only `fs`** (what we tried first). Works for today's workflow
   but forces another rollout the next time we need `crypto` or `path`.

## Consequences

- **Positive**: A bootstrap from `main` now works end-to-end. The chat
  workflow imported by the K8s Job runs without a manual "edit in UI"
  step.
- **Positive**: Future Code nodes have full access to Node built-ins.
- **Negative**: Slightly weaker sandbox — a malicious Code node could
  read pod files, open sockets, etc. Acceptable because:
  - All workflows in this repo come from the same git history we already
    trust (image scanning, etc., applies in Phase 2).
  - The n8n pod itself is unprivileged, runs as non-root, has only the
    WL-identity federated token (scoped to `Cognitive Services OpenAI
    User` on one AOAI account), and lives in a namespace with no other
    secrets of value.
- **Negative**: Code nodes must remember `$env.X` instead of
  `process.env.X`. Workflow comments should call this out.

## Related

- ADR 0013 (cluster sized to host n8n at all)
- PR #11 (Phase 1E SPA + AOAI wire-up)
- `n8n-workflows/chat.json` — comment block in the Code node enumerates
  these vm2 quirks for the next person editing it.
