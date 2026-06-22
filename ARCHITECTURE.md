# Architecture — Poly Orchestrator

## 1. Purpose

Poly Orchestrator is an **AI Visibility Strategy Platform**. It answers the question: *"When a user asks an AI search engine about a topic, does your brand appear — and if so, where and how positively?"*

It fans a single brand-mention query out to five AI providers concurrently, normalises their responses, extracts brand-mention signals, and surfaces actionable metrics (mention rate, ordinal rank, sentiment, competitor counts) via a REST API and Prometheus/Grafana observability stack.

---

## 2. High-Level System Diagram

```
          Client (curl / frontend / scheduler)
                          │
                          ▼ HTTPS
          ┌───────────────────────────────┐
          │        Nginx Ingress          │  TLS termination, rate-limit (100 req/min)
          └───────────────┬───────────────┘
                          │ HTTP/80
          ┌───────────────▼───────────────┐
          │         FastAPI App           │  Python 3.11, uvicorn 2 workers
          │   POST /api/v1/queries        │
          │   GET  /api/v1/reports        │
          │   GET  /health                │
          │   GET  /metrics               │  Prometheus scrape target
          └───────┬───────────────────────┘
                  │ async fan-out
       ┌──────────▼──────────────────────────────┐
       │        OrchestratorEngine               │
       │  asyncio.gather + Semaphore(10)         │
       └──┬──────┬──────┬──────┬──────┬──────────┘
          │      │      │      │      │
     ┌────▼─┐ ┌──▼──┐ ┌─▼───┐ ┌▼────┐ ┌▼─────┐
     │OpenAI│ │Anth.│ │Gemini│ │Pplx │ │ Groq │   httpx async + tenacity retry (3×)
     │GPT-4o│ │Claud│ │1.5pro│ │Sonar│ │LLaMA │
     └────┬─┘ └──┬──┘ └─┬───┘ └┬────┘ └┬─────┘
          └──────┴───────┴──────┴───────┘
                          │ AdapterResponse[]
          ┌───────────────▼───────────────┐
          │        BrandAnalyzer          │  Pure Python, no external deps
          │  mention detection (regex)    │
          │  ordinal rank extraction      │
          │  competitor counts            │
          │  sentiment scoring            │
          └───────────────┬───────────────┘
                          │ MentionResult[]
          ┌───────────────▼───────────────┐
          │        OrchestratorResult     │  Aggregated metrics dataclass
          │  mention_rate, avg_rank,      │
          │  avg_sentiment, failed_list   │
          └───────┬───────────────────────┘
                  │
       ┌──────────┴────────────────┐
       │                           │
┌──────▼──────┐            ┌───────▼────────┐
│ PostgreSQL  │            │ Prometheus      │
│ (asyncpg)  │            │ /metrics scrape │
│ query_      │            │                 │
│ records     │            │ Grafana          │
│ brand_      │            │ dashboard        │
│ metrics     │            └─────────────────┘
└─────────────┘
       │
┌──────▼──────┐
│   Redis     │  Result cache (TTL 300 s, allkeys-lru, 256 MB cap)
└─────────────┘
```

---

## 3. Component Breakdown

### 3.1 FastAPI Application (`src/poly_orchestrator/main.py`)

| Responsibility | Detail |
|---|---|
| App factory | `create_app()` wires middleware, routers, lifespan hooks |
| Structured logging | `structlog` — ConsoleRenderer in dev, JSONRenderer in prod |
| CORS | Open in dev, locked to `[]` in production |
| Error handling | Global `Exception` handler → 500 JSON, always logs |
| Metrics endpoint | `GET /metrics` — serves Prometheus text exposition format |

### 3.2 API Routes (`src/poly_orchestrator/api/routes/`)

| Route | Method | Handler file | Purpose |
|---|---|---|---|
| `/api/v1/queries` | POST | `queries.py` | Submit a brand query; returns full per-adapter results |
| `/api/v1/reports` | GET | `reports.py` | Aggregate report for a brand (DB-backed, stub until wired) |
| `/health` | GET | `health.py` | Liveness + readiness probe; returns adapter config list |
| `/metrics` | GET | `main.py` | Prometheus scrape endpoint |

**Request schema** (`QueryRequest`):

```python
{
  "brand":          "Amalitec",          # required
  "query_template": "Best bootcamps…",   # required, sent verbatim to each adapter
  "adapters":       ["openai", "groq"],  # optional subset; omit = all enabled
  "competitors":    ["ALX", "Andela"]    # optional; counted in each response
}
```

### 3.3 Orchestration Engine (`src/poly_orchestrator/orchestrator/engine.py`)

The core fan-out loop:

```
run(brand, query, adapters?, competitors?)
  │
  ├─ filter to target_adapters (from registry)
  ├─ create asyncio.Semaphore(max_concurrency=10)
  ├─ asyncio.gather(*[_bounded_query(name, adapter) for each])
  │     └─ adapter.safe_query(query)   ← never raises; errors → AdapterResponse.error
  │
  └─ for each succeeded response:
        BrandAnalyzer.analyze(brand, provider, content, competitors)
  │
  └─ return OrchestratorResult(mention_rate, avg_rank, avg_sentiment, ...)
```

Key design decisions:
- **`safe_query()` wraps every call** — a single provider outage never kills the whole run
- **Semaphore caps concurrency** — prevents hammering providers when many adapters are enabled
- **Adapters with blank API keys are silently skipped** at engine startup

### 3.4 AI Provider Adapters (`src/poly_orchestrator/adapters/`)

```
BaseAdapter (ABC)
    ├── OpenAIAdapter      → api.openai.com/v1/chat/completions
    ├── AnthropicAdapter   → api.anthropic.com/v1/messages
    ├── GeminiAdapter      → generativelanguage.googleapis.com/v1beta/…
    ├── PerplexityAdapter  → api.perplexity.ai/chat/completions
    └── GroqAdapter        → api.groq.com/openai/v1/chat/completions
```

Every adapter:
- Uses `httpx.AsyncClient` (non-blocking I/O)
- Decorates `query()` with `@retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=8))`
- Returns a typed `AdapterResponse` dataclass (provider, model, content, latency_ms, token counts, raw_metadata)

Adding a new provider requires only subclassing `BaseAdapter`, implementing `query()`, and registering in `ADAPTER_REGISTRY`.

### 3.5 Brand Analyzer (`src/poly_orchestrator/orchestrator/analyzer.py`)

Pure-Python text analysis, no ML dependencies:

| Signal | Method |
|---|---|
| Mention detection | `re.findall(re.escape(brand_lower), lower)` — case-insensitive |
| Ordinal rank | Regex for numbered lists (`1. Foo`, `1) Foo`); falls back to paragraph order |
| Competitor counts | Same regex per competitor name |
| Excerpt | 40-char lead-in + 120-char window around first match |
| Sentiment | Keyword intersection: 11 positive / 10 negative signals in a ±80-char window; score = `(pos − neg) / (pos + neg)` |

### 3.6 Data Layer (`src/poly_orchestrator/db/`)

```
SQLAlchemy 2.x (async) + asyncpg driver
        │
        ├── session.py      — create_async_engine + async_sessionmaker
        ├── models.py       — QueryRecord, BrandMetric ORM models
        └── repository.py   — QueryRepository (save, list_by_brand, aggregates)
```

**`query_records` table** — one row per orchestration run; stores aggregate metrics and full JSON payloads (adapter responses + mention results) for audit/replay.

**`brand_metrics` table** — daily roll-up per brand (populated by a separate job, not yet implemented in v0.1).

Migrations managed by **Alembic** with async runner; migration `001` creates both tables with appropriate indexes on `brand` and `created_at`.

### 3.7 Metrics (`src/poly_orchestrator/metrics/prometheus.py`)

| Metric | Type | Labels |
|---|---|---|
| `orchestrator_queries_total` | Counter | `brand`, `adapter` |
| `orchestrator_adapter_errors_total` | Counter | `adapter` |
| `orchestrator_query_duration_seconds` | Histogram | `adapter` |
| `orchestrator_brand_mention_rate` | Gauge | `brand` |
| `orchestrator_brand_sentiment_score` | Gauge | `brand` |
| `orchestrator_active_adapters_total` | Gauge | — |

`record_query()` is a single helper that updates all relevant metrics atomically from one call-site.

### 3.8 Configuration (`src/poly_orchestrator/config.py`)

`pydantic-settings` `BaseSettings` reads from `.env` (or OS env). Single cached instance via `@lru_cache`. All adapter API keys are optional strings; the engine skips adapters with blank keys rather than crashing.

---

## 4. Data Flow — Single Query Request

```
POST /api/v1/queries
  │
  1. Pydantic validates QueryRequest (adapter names, field lengths)
  │
  2. FastAPI injects OrchestratorEngine (singleton via Depends)
  │
  3. engine.run(brand, query, adapters, competitors)
  │     ├─ asyncio.gather → all adapters fire simultaneously
  │     │     each: httpx POST → provider API → AdapterResponse
  │     └─ BrandAnalyzer runs on each succeeded response
  │
  4. OrchestratorResult assembled (mention_rate, avg_rank, avg_sentiment)
  │
  5. QueryResponse built from result (includes per-adapter breakdown)
  │
  6. (future) QueryRepository.save(response) → PostgreSQL
  │
  7. record_query() → Prometheus gauges/counters updated
  │
  8. JSON response returned to client
```

---

## 5. Infrastructure

### 5.1 Local Development — Docker Compose

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│    app:8000  │  │ postgres:5432│  │  redis:6379  │
│ (hot-reload  │  │  poly_orch   │  │ 256MB lru    │
│  via override│  │  database)   │  │              │
└──────────────┘  └──────────────┘  └──────────────┘
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│prometheus:   │  │ grafana:3000 │  │  migrate     │
│  9090        │  │  (admin/     │  │  (one-shot   │
│              │  │   admin)     │  │  alembic up) │
└──────────────┘  └──────────────┘  └──────────────┘
```

The `migrate` service runs `alembic upgrade head` on startup and exits; all other services wait on Postgres being healthy before starting.

### 5.2 Production — Kubernetes on AWS EKS

```
Internet
  │
  ▼ HTTPS (cert-manager / Let's Encrypt)
Nginx Ingress Controller
  │ rate-limit: 100 req/min
  │ force-ssl-redirect
  ▼
Service (ClusterIP :80 → :8000)
  │
  ▼
Deployment (2–10 replicas, RollingUpdate maxUnavailable=0)
  │  Non-root UID 1001, read-only root FS, ALL caps dropped
  │  Resources: 200m–1000m CPU, 256–512Mi RAM
  ├─ ConfigMap  (non-secret env vars)
  └─ Secret     (API keys, DATABASE_URL, REDIS_URL)
       │
  HPA (CPU 70% / Mem 80% thresholds, max 10 replicas)
  TopologySpreadConstraints (spread across nodes)
  NetworkPolicy (deny-all ingress except ingress-nginx + monitoring NS)
  │
  ├── RDS PostgreSQL 15  (private subnet, encrypted, deletion-protected)
  └── ElastiCache Redis 7 (private subnet)
```

### 5.3 Cloud Infrastructure — Terraform

| Resource | Detail |
|---|---|
| VPC | 10.0.0.0/16, 3 AZs, public + private subnets, NAT Gateway |
| EKS | 1.30, SPOT managed node group, 2–10 nodes |
| RDS | PostgreSQL 15.8, encrypted at rest, 7-day backup, deletion-protected in prod |
| ElastiCache | Redis 7.1 |
| State backend | S3 bucket (encrypted) + DynamoDB lock table |

---

## 6. CI/CD Pipeline

```
Push / PR
    │
    ├─── ci.yml ────────────────────────────────────────────────────┐
    │        lint (ruff + mypy)                                      │
    │              │ pass                                            │
    │        test matrix (Python 3.11 + 3.12)                       │
    │              postgres + redis service containers               │
    │              alembic upgrade head → pytest → codecov           │
    │              │ pass                                            │
    │        build + push image → GHCR                              │
    │              (branch tag, SHA tag, latest on main)             │
    │              SBOM + provenance attestations                    │
    └────────────────────────────────────────────────────────────────┘
    │
    ├─── security.yml ──────────────────────────────────────────────┐
    │        Bandit SAST → GitHub Security tab (SARIF)               │
    │        pip-audit CVE scan → CycloneDX JSON artifact           │
    │        Trivy container scan (HIGH/CRITICAL) → SARIF            │
    │        Gitleaks secret scan (full history)                     │
    │        CodeQL Python analysis                                  │
    │        + nightly cron 02:00 UTC                                │
    └────────────────────────────────────────────────────────────────┘
    │
    └─── release.yml (on tag v*.*.*) ───────────────────────────────┐
             build + push semver + latest tags to GHCR              │
             SBOM + provenance                                       │
             auto-generate GitHub Release with digest + changelog   │
             └────────────────────────────────────────────────────────┘
```

---

## 7. Security Controls

| Layer | Control | Where |
|---|---|---|
| Secrets at rest | Never in code; `.env.example` only | repo root |
| Secrets in CI | GitHub Actions Secrets | `.github/workflows/` |
| Secrets in prod | Kubernetes Secret (or External Secrets Operator) | `infra/k8s/` |
| SAST | Bandit (`pyproject.toml` config) | pre-commit + CI |
| Dependency CVEs | pip-audit on every push | `security.yml` |
| Container CVEs | Trivy (HIGH/CRITICAL fails build) | `security.yml` |
| Secret scanning | Gitleaks pre-commit + CI (full history) | `.pre-commit-config.yaml` + CI |
| Code analysis | CodeQL Python | `security.yml` |
| Container hardening | Non-root UID 1001, `readOnlyRootFilesystem`, `capabilities: drop ALL` | `Dockerfile` + `deployment.yaml` |
| Network isolation | K8s NetworkPolicy deny-all; allow only ingress-nginx + monitoring NS | `ingress.yaml` |
| TLS | cert-manager + Let's Encrypt (Ingress) | `ingress.yaml` |
| Rate limiting | nginx annotation 100 req/min | `ingress.yaml` |

---

## 8. Observability

### Prometheus metrics

Scraped from `GET /metrics` every 15 seconds. Key alerts to configure:

| Condition | Suggested alert |
|---|---|
| `rate(orchestrator_adapter_errors_total[5m]) > 0.1` | Adapter degraded |
| `orchestrator_brand_mention_rate < 0.1` | Brand visibility critically low |
| `histogram_quantile(0.95, …query_duration_seconds_bucket…) > 10` | Latency SLO breach |
| Pod count below `minReplicas` | HPA not scaling |

### Grafana dashboard (`poly-orchestrator-v1`)

- **Query rate by adapter** — timeseries (req/s)
- **Latency p50/p95 by adapter** — timeseries
- **Brand mention rate** — stat panel with threshold colouring (red < 0.3, yellow < 0.7, green ≥ 0.7)
- **Brand sentiment** — gauge (−1 to +1)
- **Adapter errors last 1h** — stat panel
- **Brand** template variable — filters all panels to one or multiple brands

### Structured logs

JSON in production (`structlog.processors.JSONRenderer`). Key fields:

| Event | Fields |
|---|---|
| `adapter_query_start` | `adapter`, `brand` |
| `adapter_query_done` | `adapter`, `latency_ms`, `error` (null if ok) |
| `orchestration_complete` | `brand`, `mention_rate`, `avg_rank`, `failed` |
| `adapter_skipped` | `adapter`, `reason` |
| `unhandled_exception` | `path`, `error` |

---

## 9. Directory Map

```
poly-orchestrator-challenge/
├── src/poly_orchestrator/
│   ├── __init__.py            version string
│   ├── config.py              Pydantic BaseSettings
│   ├── main.py                FastAPI app factory + /metrics
│   ├── adapters/
│   │   ├── base.py            BaseAdapter ABC + AdapterResponse
│   │   ├── openai_adapter.py
│   │   ├── anthropic_adapter.py
│   │   ├── gemini_adapter.py
│   │   ├── perplexity_adapter.py
│   │   └── groq_adapter.py
│   ├── api/
│   │   ├── deps.py            FastAPI Depends (engine singleton)
│   │   ├── schemas.py         Pydantic v2 request/response models
│   │   └── routes/
│   │       ├── health.py      GET /health
│   │       ├── queries.py     POST /api/v1/queries
│   │       └── reports.py     GET /api/v1/reports
│   ├── db/
│   │   ├── models.py          QueryRecord, BrandMetric ORM
│   │   ├── session.py         async engine + sessionmaker
│   │   └── repository.py      QueryRepository CRUD
│   ├── metrics/
│   │   └── prometheus.py      counters, histograms, gauges, record_query()
│   └── orchestrator/
│       ├── engine.py          OrchestratorEngine (fan-out, semaphore)
│       └── analyzer.py        BrandAnalyzer (regex, rank, sentiment)
├── tests/
│   ├── unit/
│   │   ├── test_analyzer.py   8 unit tests
│   │   └── test_engine.py     5 unit tests
│   └── integration/
│       └── test_api.py        5 integration tests
├── migrations/
│   ├── env.py                 async Alembic runner
│   └── versions/001_initial_schema.py
├── infra/
│   ├── k8s/                   namespace, configmap, secret.yaml.example,
│   │                          deployment, service, hpa, ingress+networkpolicy
│   └── terraform/             main.tf (VPC+EKS+RDS+Redis), variables, outputs
├── monitoring/
│   ├── prometheus.yml
│   └── grafana/
│       ├── datasource.yml
│       └── dashboards/poly-orchestrator.json
├── .github/workflows/
│   ├── ci.yml                 lint → test matrix → build+push
│   ├── security.yml           bandit, pip-audit, trivy, gitleaks, codeql
│   └── release.yml            semver tag → GHCR + GitHub Release
├── Dockerfile                 2-stage build (builder + production)
├── docker-compose.yml         full local stack
├── docker-compose.override.yml dev hot-reload
├── pyproject.toml             Hatch build, Ruff, Mypy, Bandit, pytest
├── alembic.ini
├── .env.example               all env vars documented (no real secrets)
└── .pre-commit-config.yaml    ruff, mypy, bandit, gitleaks, secret detection
```

---

## 10. Key Design Decisions

| Decision | Rationale |
|---|---|
| `asyncio.gather` with `Semaphore` | Fan-out to 5 providers in parallel; semaphore prevents runaway concurrency when more adapters are added |
| `safe_query()` wrapper | One failing provider must never crash the whole run; partial results are more useful than a 500 |
| Tenacity retry (3×, exponential backoff) | AI provider APIs are occasionally flaky; retrying before surfacing an error reduces noise |
| `adapterresponse.error` field instead of exceptions | Keeps error paths as data, making serialisation and downstream analysis trivial |
| Pydantic v2 for all I/O schemas | Runtime validation, auto-generated OpenAPI docs, type safety at the boundary |
| Alembic async runner | Matches the rest of the async stack; avoids a synchronous DB call during migration |
| Non-root container + `readOnlyRootFilesystem` | Defense-in-depth; limits blast radius if a provider's response triggers an unexpected code path |
| `ENABLED_ADAPTERS` comma-separated env var | Ops can disable a provider without a code change or redeploy |
