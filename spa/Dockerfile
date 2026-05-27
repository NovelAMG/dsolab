# Multi-stage build for the SPA.
#
# Stage 1: build the Vite bundle with build-time env vars.
# Stage 2: serve static files from nginx:alpine. Tiny image (~50 MB).
#
# Build args (passed by scripts/08-build-and-push-spa.sh):
#   VITE_SPA_CLIENT_ID   — SPA app reg client ID
#   VITE_TENANT_ID       — Entra tenant ID
#   VITE_N8N_API_SCOPE   — Scope to request for n8n webhook (e.g., api://9d.../access_as_user)
#   VITE_REDIRECT_URI    — Where Entra redirects after login

# ── Stage 1: build ─────────────────────────────────────────
FROM node:22-alpine AS builder
WORKDIR /app

# Install deps separately so layer caches when source changes but deps don't.
COPY package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund

# Bake env vars into the bundle (Vite replaces them at build time, NOT runtime).
ARG VITE_SPA_CLIENT_ID
ARG VITE_TENANT_ID
ARG VITE_N8N_API_SCOPE
ARG VITE_REDIRECT_URI
ENV VITE_SPA_CLIENT_ID=${VITE_SPA_CLIENT_ID}
ENV VITE_TENANT_ID=${VITE_TENANT_ID}
ENV VITE_N8N_API_SCOPE=${VITE_N8N_API_SCOPE}
ENV VITE_REDIRECT_URI=${VITE_REDIRECT_URI}

COPY . .
RUN npm run build

# ── Stage 2: serve ─────────────────────────────────────────
FROM nginx:alpine AS runtime

# OCI image annotations — read by Defender for Cloud's container-to-source
# mapping (https://learn.microsoft.com/azure/defender-for-cloud/container-image-mapping).
# Without these the image-to-repo link doesn't appear in DevOps security and
# code-to-runtime CVE recommendations can't be tied back to NovelAMG/dsolab.
# Cosign signatures alone do NOT feed this mapping — it reads OCI labels.
ARG GITHUB_SHA
ARG BUILD_DATE
LABEL org.opencontainers.image.source="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.url="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.title="dsolab/spa"
LABEL org.opencontainers.image.description="DSO lab SPA — Vite/React front-end with MSAL"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.revision="${GITHUB_SHA}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"

# nginx-default config doesn't do SPA fallback. Replace it.
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Copy built assets.
COPY --from=builder /app/dist /usr/share/nginx/html

# Run nginx as a non-root user (Defender / restricted PSA-friendly).
RUN sed -i 's/user.*nginx.*/user nginx;/' /etc/nginx/nginx.conf \
 && touch /var/run/nginx.pid \
 && chown -R nginx:nginx /var/cache/nginx /var/run/nginx.pid /usr/share/nginx/html

USER nginx
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
