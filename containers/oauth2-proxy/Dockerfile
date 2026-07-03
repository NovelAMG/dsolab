# Rehost the upstream oauth2-proxy image in our own ACR.
# See containers/n8n/Dockerfile for the full rationale (Defender for Cloud
# code-to-cloud mapping needs the image to live in a registry Defender can
# scan, i.e. ours — not quay.io).
#
# Bump OAUTH2_PROXY_VERSION here (and in the workflow matrix) for upstream
# releases — this file does not need to change for a version bump.
ARG OAUTH2_PROXY_VERSION=v7.7.1
FROM quay.io/oauth2-proxy/oauth2-proxy:${OAUTH2_PROXY_VERSION}

ARG GITHUB_SHA
ARG BUILD_DATE
ARG OAUTH2_PROXY_VERSION

LABEL org.opencontainers.image.source="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.url="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.title="dsolab/oauth2-proxy"
LABEL org.opencontainers.image.description="Rehosted oauth2-proxy (upstream quay.io/oauth2-proxy/oauth2-proxy) for code-to-cloud mapping"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${OAUTH2_PROXY_VERSION}"
LABEL org.opencontainers.image.revision="${GITHUB_SHA}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.base.name="quay.io/oauth2-proxy/oauth2-proxy:${OAUTH2_PROXY_VERSION}"
