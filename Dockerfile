FROM python:3.11-slim

LABEL org.opencontainers.image.title="Poly Orchestrator" \
      org.opencontainers.image.description="AI Visibility Orchestrator" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.source="https://github.com/Ayamigah16/poly-ochestrator-challenge"

# gcc + libpq-dev are needed at install time to compile asyncpg; libpq5 is the runtime lib.
# All in one layer so build tools don't inflate a separate layer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libpq-dev libpq5 curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1001 appgroup \
    && useradd --uid 1001 --gid appgroup --no-create-home appuser

WORKDIR /app

COPY pyproject.toml README.md ./
COPY src/ src/

RUN pip install --upgrade pip && \
    pip install --no-cache-dir .

COPY migrations/ migrations/
COPY alembic.ini .

RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["python", "-m", "uvicorn", "poly_orchestrator.main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "2", "--log-level", "info"]
