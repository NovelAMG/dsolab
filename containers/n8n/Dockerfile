# Rehost the upstream n8n image in our own ACR.
#
# Why this exists (see conversation in the Defender for Cloud code-to-cloud
# thread): images pulled straight from a third-party registry
# (docker.n8n.io) can never get the "Code" or "Build" legs of Defender's
# development-phases diagram — Defender has no credentials to scan a
# registry it doesn't own, and there's no source repo to attribute the
# image to. Runtime detection still works (agentless AKS sensor reads the
# running container directly), but Ship/Build/Code stay empty.
#
# This Dockerfile doesn't change n8n at all — it's a 1-layer rehost that:
#   1. Pulls the exact upstream n8n release (pinned by build arg).
#   2. Adds OCI source labels so Defender's container-to-source mapping
#      (https://learn.microsoft.com/azure/defender-for-cloud/container-image-mapping)
#      can link the image back to NovelAMG/dsolab.
#   3. Gets pushed to acrdsolabxsqb via GitHub Actions, so it's scanned by
#      the Defender CLI (Build) and by ACR's own MDVM scan (Ship), same as
#      the spa image.
#
# Bump N8N_VERSION here (and in the workflow matrix) to pick up upstream
# releases — this file does not need to change for a version bump.
ARG N8N_VERSION=1.69.0
FROM docker.n8n.io/n8nio/n8n:${N8N_VERSION}

ARG GITHUB_SHA
ARG BUILD_DATE
ARG N8N_VERSION

LABEL org.opencontainers.image.source="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.url="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.title="dsolab/n8n"
LABEL org.opencontainers.image.description="Rehosted n8n (upstream docker.n8n.io/n8nio/n8n) for code-to-cloud mapping"
LABEL org.opencontainers.image.licenses="Sustainable Use License (n8n)"
LABEL org.opencontainers.image.version="${N8N_VERSION}"
LABEL org.opencontainers.image.revision="${GITHUB_SHA}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.base.name="docker.n8n.io/n8nio/n8n:${N8N_VERSION}"
