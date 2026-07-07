# Poly Orchestrator

> **AI Visibility Strategy Platform** — Fan-out brand-mention queries across OpenAI, Anthropic, Google, Perplexity, Groq, and Mistral simultaneously. Track mention frequency, ranking position, and competitor comparisons in a single dashboard.

[![CI](https://github.com/Ayamigah16/poly-ochestrator-challenge/actions/workflows/ci.yml/badge.svg)](https://github.com/Ayamigah16/poly-ochestrator-challenge/actions/workflows/ci.yml)
[![Security](https://github.com/Ayamigah16/poly-ochestrator-challenge/actions/workflows/security.yml/badge.svg)](https://github.com/Ayamigah16/poly-ochestrator-challenge/actions/workflows/security.yml)
[![Coverage](https://img.shields.io/codecov/c/github/Ayamigah16/poly-ochestrator-challenge)](https://codecov.io/gh/Ayamigah16/poly-ochestrator-challenge)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      FastAPI REST API                        │
│              /queries  /reports  /health  /metrics           │
└───────────────────────┬─────────────────────────────────────┘
                        │
           ┌────────────▼─────────────┐
           │   Orchestration Engine   │
           │  (async fan-out + merge) │
           └──┬───┬───┬───┬───┬──┬───┘
              │   │   │   │   │  │
     ┌────────┘   │   │   │   │  └──────────┐
     ▼            ▼   ▼   ▼   ▼             ▼
  OpenAI    Anthropic  Google  Perplexity  Groq  Mistral
  (GPT-4o)  (Claude)  (Gemini) (Sonar)  (LLaMA) (Large)
                │   │   │   │   │   │
             ┌──▼───▼───▼───▼───▼───▼──┐
             │      Brand Analyzer      │
             │  (mention detect, rank,  │
             │   score, competitors)    │
             └──────────┬───────────────┘
                        │
          ┌─────────────▼──────────────┐
          │    PostgreSQL + Redis       │
          │  (results + cached queries) │
          └────────────────────────────┘
```

## Quick Start

### Prerequisites

- Docker & Docker Compose v2+
- GNU Make (optional)

### Run locally with Docker Compose

```bash
# 1. Clone and enter
git clone https://github.com/Ayamigah16/poly-ochestrator-challenge.git
cd poly-ochestrator-challenge

# 2. Configure secrets
cp .env.example .env
$EDITOR .env   # Add your AI provider API keys

# 3. Boot the full stack (runs migrations automatically)
./scripts/compose-deploy.sh

# 4. Verify
curl http://localhost:8000/health
```

Services started:

| Service    | URL                                            |
|------------|------------------------------------------------|
| API        | <http://localhost:8000>                        |
| API Docs   | <http://localhost:8000/docs>                   |
| Prometheus | <http://localhost:9090>                        |
| Grafana    | <http://localhost:3000>                        |

### Run in development mode

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pre-commit install

# Start backing services only
docker compose up -d postgres redis

# Run the app with hot-reload
python -m uvicorn poly_orchestrator.main:app --reload --host 0.0.0.0 --port 8000
```

## API Reference

### Submit a brand-visibility query

```http
POST /api/v1/queries
Content-Type: application/json

{
  "brand": "Amalitec",
  "query_template": "What are the best tech training bootcamps in Ghana?",
  "adapters": ["openai", "anthropic", "google", "perplexity", "groq", "mistral"],
  "competitors": ["ALX", "Andela", "Decagon"]
}
```

### Get a report for a brand

```http
GET /api/v1/reports?brand=Amalitec&limit=10
```

### Health check

```http
GET /health
```

## AI Providers

| Adapter     | Provider  | Model                  |
|-------------|-----------|------------------------|
| `openai`    | OpenAI    | GPT-4o                 |
| `anthropic` | Anthropic | Claude 3.5 Sonnet      |
| `google`    | Google    | Gemini 1.5 Pro         |
| `perplexity`| Perplexity| Sonar Pro              |
| `groq`      | Groq      | LLaMA 3.1 70B          |
| `mistral`   | Mistral AI| mistral-large-latest   |

## Project Structure

```
poly-orchestrator-challenge/
├── src/poly_orchestrator/       # Application source
│   ├── adapters/                # Per-provider LLM adapters (6 providers)
│   ├── api/                     # FastAPI routes & schemas
│   ├── db/                      # SQLAlchemy models & repository
│   ├── metrics/                 # Prometheus instrumentation
│   └── orchestrator/            # Core fan-out engine & analyzer
├── tests/                       # Unit + integration tests
├── migrations/                  # Alembic DB migrations
├── infra/
│   ├── k8s/                     # Kubernetes manifests (Deployment, HPA, Ingress)
│   └── terraform/               # IaC — EKS module (root) + ECS Fargate module (ecs/)
├── docs/                        # Architecture decisions & deployment comparisons
├── monitoring/                  # Prometheus config + Grafana dashboard
├── scripts/                     # Deployment automation (compose, k8s, terraform)
├── .github/workflows/           # CI/CD pipelines
├── Dockerfile                   # Single-stage production image
└── docker-compose.yml           # Full local stack
```

## Deployment

### Docker Compose (local / dev)

```bash
./scripts/compose-deploy.sh          # build → migrate → start
./scripts/smoke-test.sh              # end-to-end health + API check
```

### Kubernetes (kind or EKS)

```bash
# Bootstrap kind cluster (local)
kind create cluster --name poly
kind load docker-image poly-orchestrator:local --name poly

# Deploy (applies manifests + runs migration Job + watches rollout)
./scripts/k8s-deploy.sh --image poly-orchestrator:local

# Rollback
./scripts/k8s-rollback.sh
```

### AWS — ECS Fargate or EKS (Terraform)

```bash
# One-time: provision S3 state bucket in eu-west-1
./scripts/terraform-bootstrap.sh

# Plan + apply ECS infrastructure
./scripts/terraform-apply.sh --env staging --platform ecs

# Plan + apply EKS infrastructure
./scripts/terraform-apply.sh --env staging --platform eks
```

See [docs/ecs-vs-eks.md](docs/ecs-vs-eks.md) for a full ECS vs EKS cost and feature comparison.

## Branching Strategy

```text
main         ← production-ready, protected, tags drive releases
  └─ develop ← integration branch
       └─ feature/<name>  ← all feature work
```

PRs target `develop`; `develop` → `main` on release. Direct push to `main` and `develop` is blocked.

## CI/CD

| Workflow       | Trigger        | Steps                                      |
|----------------|----------------|--------------------------------------------|
| `ci.yml`       | push / PR      | lint → type-check → test → build image     |
| `security.yml` | push + nightly | Bandit SAST, Safety deps, Trivy image scan |
| `release.yml`  | tag `v*`       | Build, push GHCR, create GitHub Release    |

## Observability

- **Structured logging** via `structlog` (JSON in production)
- **Prometheus metrics** at `/metrics`:
  - `orchestrator_queries_total` — counter by adapter + brand
  - `orchestrator_query_duration_seconds` — histogram
  - `orchestrator_brand_mention_score` — gauge
  - `orchestrator_adapter_errors_total` — counter by adapter
- **Grafana dashboard** pre-provisioned at `monitoring/grafana/`

## Security Controls

| Layer           | Control                                                           |
|-----------------|-------------------------------------------------------------------|
| Secrets         | `.env` (local), GitHub Secrets (CI), K8s/Secrets Manager (prod)   |
| SAST            | Bandit on every push                                              |
| Dependency scan | `pip-audit` / Safety in CI                                        |
| Container scan  | Trivy on every image build                                        |
| Secret scan     | Gitleaks pre-commit hook                                          |
| Image           | Non-root user (`appuser`), minimal `python:3.11-slim` base        |
| Network         | K8s NetworkPolicy (deny-all default)                              |

## License

MIT — see [LICENSE](LICENSE).
