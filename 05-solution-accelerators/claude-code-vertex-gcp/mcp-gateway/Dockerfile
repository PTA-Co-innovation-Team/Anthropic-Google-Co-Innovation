# syntax=docker/dockerfile:1.7
# =============================================================================
# MCP Gateway container image — uv-based build.
#
# Follows the pattern Google publishes for MCP-on-Cloud-Run: use the
# official `uv` image for fast, reproducible dependency installs via a
# lockfile, then copy the resulting venv into a slim runtime image.
#
# Why uv instead of pip?
#   * Orders of magnitude faster on cold builds — matters when your team
#     iterates on the server.
#   * Produces a uv.lock for reproducibility.
#   * This is the pattern Google's own samples use.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: build dependencies with uv.
# -----------------------------------------------------------------------------
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    # Install into /app/.venv so the runtime image copies a single dir.
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

# Copy only the files needed to resolve deps first, so Docker can cache
# this layer across code-only changes.
COPY pyproject.toml ./
# The lockfile is optional; if absent, uv will produce one during sync.
# We tolerate either case with a wildcard glob.
COPY uv.lock* ./

# Pre-fetch dependencies WITHOUT the project source. This keeps the
# dependency layer independent of source changes.
RUN uv sync --no-dev --no-install-project --frozen || uv sync --no-dev --no-install-project

# Now copy the application source and install the project itself.
COPY server.py ./
COPY tools ./tools

RUN uv sync --no-dev --frozen || uv sync --no-dev


# -----------------------------------------------------------------------------
# Stage 2: slim runtime.
# -----------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH" \
    PORT=8080

RUN groupadd --system app && useradd --system --gid app --home /app app
WORKDIR /app

# Copy the pre-built venv and the application.
COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --chown=app:app server.py ./
COPY --chown=app:app tools ./tools

USER app
EXPOSE 8080

# FastMCP reads $PORT internally (we pass it in server.py). No shell form
# needed for variable expansion because we handle PORT in Python.
CMD ["python", "server.py"]
