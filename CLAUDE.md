# Poly Orchestrator — Claude Code Guide

## Project overview
AI Visibility Orchestrator that fans out brand-mention queries to multiple LLM providers concurrently (OpenAI, Anthropic, Google, Perplexity, Groq), aggregates responses, detects brand mentions, and tracks metrics over time.

## Tech stack
- **Runtime:** Python 3.11+, FastAPI, uvicorn
- **Async I/O:** asyncio, httpx, asyncpg
- **Database:** PostgreSQL 15 (async via SQLAlchemy 2.x + asyncpg)
- **Cache:** Redis 7
- **Migrations:** Alembic
- **Observability:** structlog (JSON), prometheus-client
- **Container:** Docker (multi-stage), Docker Compose v2
- **CI/CD:** GitHub Actions
- **IaC:** Terraform + Kubernetes manifests

## Common commands

```bash
# Install deps (dev mode)
pip install -e ".[dev]"

# Run tests
pytest

# Run with hot-reload (backing services must be up)
uvicorn poly_orchestrator.main:app --reload

# Boot full stack
docker compose up -d

# Run migrations
alembic upgrade head

# Lint + format
ruff check --fix src tests && ruff format src tests

# Type check
mypy src

# SAST
bandit -c pyproject.toml -r src

# Dependency audit
pip-audit
```

## Source layout
```
src/poly_orchestrator/
├── main.py          # FastAPI app factory + lifespan
├── config.py        # Pydantic BaseSettings (reads .env)
├── adapters/        # One file per AI provider
├── api/             # Routes, schemas, deps
├── db/              # ORM models, session, repository
├── metrics/         # Prometheus counters/histograms
└── orchestrator/    # Fan-out engine + brand analyzer
```

## Branch conventions
- Feature work goes in `feature/<name>` branched from `develop`
- PRs target `develop`; `develop` → `main` on release
- `main` and `develop` are protected — no direct push

## Secrets
Never commit `.env`. Use `.env.example` as the template. In CI, use GitHub Secrets. In prod, use Kubernetes Secrets or a secrets manager.

## Adding a new AI adapter
1. Create `src/poly_orchestrator/adapters/<name>_adapter.py`
2. Subclass `BaseAdapter` and implement `async def query(self, prompt: str) -> AdapterResponse`
3. Register in `AdapterRegistry` inside `adapters/__init__.py`
4. Add the corresponding env vars to `.env.example`
5. Write unit tests under `tests/unit/test_adapters.py`
