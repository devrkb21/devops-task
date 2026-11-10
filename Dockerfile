# syntax=docker/dockerfile:1

# Pinned to an exact Python patch release and Alpine release so builds are reproducible.
# Dependabot (.github/dependabot.yml) opens a PR when a newer tag is published.
ARG PYTHON_IMAGE=python:3.13.18-alpine3.24

# ---------------------------------------------------------------------------
# Stage 1: install dependencies into a virtualenv. Nothing from this stage
# ships except /opt/venv and the compiled application code.
# ---------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# Copy only the lock file first so this layer stays cached until dependencies change.
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --require-hashes --no-deps -r requirements.txt \
    && /opt/venv/bin/pip uninstall --yes pip

COPY app/ ./app/
# Precompile bytecode: the runtime filesystem is read-only, so Python cannot write .pyc later.
RUN python -m compileall -q app /opt/venv/lib

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime image.
# ---------------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime

ARG APP_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
ARG SOURCE_URL=unknown

LABEL org.opencontainers.image.title="devops-task" \
      org.opencontainers.image.description="Small FastAPI service with health checks and Prometheus metrics" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.licenses="MIT"

# Dedicated unprivileged user with a fixed UID, so Kubernetes runAsNonRoot can verify it.
# pip is removed from the base image: nothing installs packages at runtime.
RUN addgroup -S -g 10001 app \
    && adduser -S -D -H -u 10001 -G app -s /sbin/nologin app \
    && python -m pip uninstall --yes pip

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION} \
    PORT=8080

WORKDIR /srv
COPY --from=builder /opt/venv /opt/venv
# Code stays owned by root, so the app user can read it but not modify it.
COPY --from=builder /build/app ./app

USER 10001:10001
EXPOSE 8080
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-m", "app.healthcheck"]

ENTRYPOINT ["python", "-m", "app"]
