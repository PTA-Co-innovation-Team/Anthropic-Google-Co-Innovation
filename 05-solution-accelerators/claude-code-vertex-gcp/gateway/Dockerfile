# syntax=docker/dockerfile:1.7
# =============================================================================
# LLM Gateway — production container image.
#
# Multi-stage build:
#   * builder: installs dependencies into a venv
#   * runtime: copies only the venv + app, runs as a non-root user
#
# The result is small (~120 MB) and has no build toolchain in the final
# image. Compatible with Cloud Run's buildpacks cache.
# =============================================================================

# -----------------------------------------------------------------------------
# Builder stage.
# We use the full python image (not slim) here because some transitive deps
# need build tooling. The result is thrown away.
# -----------------------------------------------------------------------------
FROM python:3.12-slim AS builder

# Don't write .pyc files, don't buffer stdout. Helps keep layers small and
# makes Cloud Logging see log lines in real time during startup.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# Create a venv so the final image can copy a single directory.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build
COPY requirements.txt ./

# Install exactly what's in requirements.txt. No extras, no dev deps.
RUN pip install --upgrade pip && pip install -r requirements.txt


# -----------------------------------------------------------------------------
# Runtime stage.
# -----------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    # Tell FastAPI/uvicorn which module to import. Cloud Run passes $PORT
    # at runtime; the CMD below honors it.
    PORT=8080

# Run as a non-root user. Cloud Run does not require this, but it is
# defense-in-depth in case of a sandbox escape.
RUN groupadd --system app && useradd --system --gid app --home /app app
WORKDIR /app

# Copy the prebuilt venv from the builder stage.
COPY --from=builder /opt/venv /opt/venv

# Copy the application source. Ownership assigned to the unprivileged user.
COPY --chown=app:app app ./app

USER app

EXPOSE 8080

# Uvicorn entrypoint. Workers=1 because Cloud Run scales horizontally by
# spawning more container instances; multiple workers inside one container
# would only add memory pressure.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --workers 1"]
