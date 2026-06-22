# ─── Stage 1: dependency builder ─────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build

# System deps for asyncpg compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml README.md ./
COPY src/ src/

RUN pip install --upgrade pip && \
    pip install --no-cache-dir build && \
    pip wheel --no-cache-dir --wheel-dir /build/wheels -e ".[dev]" || true && \
    pip install --no-cache-dir --target /build/site-packages -e .


# ─── Stage 2: production image ────────────────────────────────────────────────
FROM python:3.11-slim AS production

LABEL org.opencontainers.image.title="Poly Orchestrator" \
      org.opencontainers.image.description="AI Visibility Orchestrator" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.source="https://github.com/Ayamigah16/poly-ochestrator-challenge"

# Security: non-root user
RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup --no-create-home appuser

# System runtime libs only (asyncpg needs libpq)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /build/site-packages /usr/local/lib/python3.11/site-packages

# Re-install without build tools (clean production install)
COPY pyproject.toml README.md ./
COPY src/ src/

RUN pip install --no-cache-dir --no-deps -e . && \
    pip install --no-cache-dir \
        fastapi uvicorn[standard] httpx pydantic pydantic-settings \
        sqlalchemy asyncpg alembic redis structlog tenacity \
        prometheus-client google-generativeai openai anthropic python-dotenv

COPY migrations/ migrations/
COPY alembic.ini .

# Ownership
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "poly_orchestrator.main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--log-level", "info"]
