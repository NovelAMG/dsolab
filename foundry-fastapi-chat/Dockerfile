# LAB ONLY — deliberately vulnerable. Do not use as a production template.
#
# Base is pinned to a stale python:3.11 build on Debian 12 (bookworm), which is
# still in support. Same reasoning as spa/Dockerfile: an EOL distro stops
# receiving security-database updates, so scanners can no longer attribute new
# CVEs to it. A stale build on a supported branch gives real, trackable
# findings instead of a scanner blind spot.
FROM python:3.11.7-slim-bookworm

# Read by Defender for Cloud's container-to-source mapping. Without these the
# image-to-repo link doesn't appear in DevOps security.
LABEL org.opencontainers.image.source="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.url="https://github.com/NovelAMG/dsolab"
LABEL org.opencontainers.image.title="dsolab/foundry-chat"
LABEL org.opencontainers.image.description="Foundry chat console (FastAPI) — deliberately vulnerable lab workload"
LABEL org.opencontainers.image.licenses="MIT"

ARG GITHUB_SHA=local
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.revision="${GITHUB_SHA}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY static/ ./static/

RUN useradd --uid 10001 --create-home appuser
USER 10001

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
