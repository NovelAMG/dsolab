# ADR 0003 — Drop Entra Agent ID; use vanilla Entra app regs + Workload Identity

**Status**: Accepted
**Date**: 2026-05-22
**Phase**: 1A (informs entire lab architecture)

## Context

Microsoft Learn ships a sample (`astaykov/n8n-aca`) that integrates n8n with **Entra Agent ID**, an identity layer purpose-built for AI agents. The sample creates four Entra objects: Blueprint app registration, Agent Identity service principal, Agent User account, and an SPA app registration.

We evaluated using Entra Agent ID for this lab.

## Decision

**Drop Entra Agent ID from the lab architecture.** Use only:

1. **SPA app registration** (`spa-dsolab`) for the user-facing chat UI.
2. **n8n API app registration** (`n8n-api-dsolab`) for oauth2-proxy to validate bearer tokens against.
3. **User-assigned managed identity** (`mi-n8n-aoai-dsolab`) with **workload identity federation** for the n8n pod to call Azure OpenAI.

Total: 2 app regs + 1 managed identity.

## Why drop it

- **Tenant role gate**: Entra Agent ID setup requires Global Administrator role activation. The rest of the lab needs only Application Administrator. Removing Agent ID removes the GA dependency entirely.
- **Object count**: 4 Entra objects to manage vs 2 — twice the surface area for misconfiguration, twice the cleanup burden when tearing the lab down.
- **n8n community node dependency**: `@astaykov/n8n-nodes-entraagentid` is a third-party node that has to be installed into n8n. Dropping it lets us run vanilla n8n.
- **Conceptual overhead for the learner**: a security engineer learning DevOps does not need to also learn Entra Agent ID's Blueprint/FIC/Agent User abstractions on day one. The lab's goal is DevSecOps for AI workloads, not Entra Agent ID itself.
- **Plumbing cost is comparable**: without Agent ID we wire SPA → oauth2-proxy → n8n manually using vanilla OAuth 2.0 + workload identity. That's standard skill and useful beyond this lab.

## What we lose

- **The "Agent User" persona** as a first-class Entra object — useful for delegated calls into Microsoft Graph MCP Server. We compensate by passing the end-user's OID into the Azure OpenAI request body's `user` field per the `gain-end-user-context-ai` doc; this satisfies Defender for AI Services attribution and Purview DSPM for AI without needing an Agent User account.
- **Graph MCP Server integration** — the MS sample showcases the agent calling Microsoft Graph via the MCP Server using delegated tokens. Out of scope for this lab.

## When to reconsider

If the lab evolves to need:
- Real delegated calls to Microsoft Graph from the agent on behalf of the user, or
- Multiple agents with distinct identities + governance lifecycle in Entra,

then Entra Agent ID becomes the right tool. For chat + AOAI + lab-scale DevSecOps demo, it's overkill.
