# Runbook — Poly Orchestrator

Operational reference for on-call engineers, DevOps, and anyone deploying or debugging the platform.

---

## Table of Contents

1. [Service Overview](#1-service-overview)
2. [Prerequisites](#2-prerequisites)
3. [Local Development Setup](#3-local-development-setup)
4. [Docker Compose — Full Stack](#4-docker-compose--full-stack)
5. [Database Migrations](#5-database-migrations)
6. [Running Tests](#6-running-tests)
7. [Linting & Type Checking](#7-linting--type-checking)
8. [Security Scans](#8-security-scans)
9. [Environment Variables Reference](#9-environment-variables-reference)
10. [Adding a New AI Adapter](#10-adding-a-new-ai-adapter)
11. [Production Kubernetes Deployment](#11-production-kubernetes-deployment)
12. [Terraform — Cloud Provisioning](#12-terraform--cloud-provisioning)
13. [Monitoring & Alerting](#13-monitoring--alerting)
14. [Release Process](#14-release-process)
15. [Incident Response Playbooks](#15-incident-response-playbooks)
16. [CI/CD Reference](#16-cicd-reference)
17. [Common Commands Cheat-Sheet](#17-common-commands-cheat-sheet)

---

## 1. Service Overview

| Property | Value |
|---|---|
| Language | Python 3.11+ |
| Framework | FastAPI + uvicorn |
| Database | PostgreSQL 15 (async via asyncpg) |
| Cache | Redis 7 |
| Registry | `ghcr.io/ayamigah16/poly-ochestrator-challenge` |
| Default port | 8000 |
| Metrics | `GET /metrics` (Prometheus) |
| Health | `GET /health` |
| Docs | `GET /docs` (Swagger UI) |

---

## 2. Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| Python | 3.11 | `pyenv install 3.11` |
| Docker | 24.0 | [docs.docker.com](https://docs.docker.com/get-docker/) |
| Docker Compose | v2.20 | included with Docker Desktop |
| git | 2.40 | OS package manager |
| kubectl | 1.30 | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| Terraform | 1.9 | [developer.hashicorp.com](https://developer.hashicorp.com/terraform/install) |
| AWS CLI | 2.x | `pip install awscli` |

---

## 3. Local Development Setup

```bash
# 1. Clone
git clone https://github.com/Ayamigah16/poly-ochestrator-challenge.git
cd poly-ochestrator-challenge

# 2. Create virtualenv
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate

# 3. Install all dependencies (including dev tools)
pip install -e ".[dev]"

# 4. Copy environment template and fill in your API keys
cp .env.example .env
$EDITOR .env

# 5. Install pre-commit hooks (run once per clone)
pre-commit install

# 6. Start backing services only
docker compose up -d postgres redis

# 7. Run database migrations
alembic upgrade head

# 8. Start the application with hot-reload
uvicorn poly_orchestrator.main:app --reload --host 0.0.0.0 --port 8000
```

Verify it is running:
```bash
curl http://localhost:8000/health
# Expected: {"status":"ok","version":"0.1.0","database":"ok","redis":"ok","adapters_configured":["openai",...]}
```

---

## 4. Docker Compose — Full Stack

### Start the full stack

```bash
# Builds the image locally, starts all 6 services
docker compose up -d

# Follow logs from all services
docker compose logs -f

# Follow logs from a single service
docker compose logs -f app
```

### Service URLs (local)

| Service | URL |
|---|---|
| API | http://localhost:8000 |
| Swagger UI | http://localhost:8000/docs |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 (admin / admin) |
| PostgreSQL | localhost:5432 (poly / poly_pass / poly_orchestrator) |
| Redis | localhost:6379 |

### Restart a single service

```bash
docker compose restart app
```

### Rebuild after code change

```bash
docker compose build app && docker compose up -d app
```

### Stop and remove all containers + volumes

```bash
docker compose down -v
```

> **Warning:** `-v` removes the postgres and redis volumes. All data is lost.

### Development mode (hot-reload)

`docker-compose.override.yml` is automatically applied and mounts `./src` into the container with `--reload`:

```bash
docker compose up -d          # override is applied automatically in dev
```

---

## 5. Database Migrations

Migrations are managed by Alembic. The async runner is in `migrations/env.py`.

```bash
# Apply all pending migrations (run after pulling new code)
alembic upgrade head

# Roll back one migration
alembic downgrade -1

# Roll back to a specific revision
alembic downgrade 001

# Show current revision
alembic current

# Show migration history
alembic history --verbose

# Generate a new empty migration
alembic revision --autogenerate -m "describe your change"
```

> **In Docker Compose:** the `migrate` service runs `alembic upgrade head` automatically on stack startup. You only need to run migrations manually in local dev mode.

> **In Kubernetes:** run migrations as a pre-deploy Job (or the `migrate` init container pattern) before rolling out the new Deployment.

---

## 6. Running Tests

```bash
# Run all tests with coverage
pytest

# Run only unit tests
pytest tests/unit/

# Run only integration tests
pytest tests/integration/

# Run a specific test file
pytest tests/unit/test_analyzer.py -v

# Run a specific test
pytest tests/unit/test_analyzer.py::test_rank_from_numbered_list -v

# Run with coverage report (HTML)
pytest --cov=poly_orchestrator --cov-report=html
open htmlcov/index.html

# Run without coverage (faster during development)
pytest --no-cov
```

### Required environment for integration tests

Integration tests need postgres and redis reachable. Either:
- Have `docker compose up -d postgres redis` running, or
- Set `DATABASE_URL` and `REDIS_URL` in your shell to point at existing instances

The CI pipeline spins up service containers automatically.

---

## 7. Linting & Type Checking

```bash
# Lint (auto-fix safe issues)
ruff check --fix src tests

# Format
ruff format src tests

# Check formatting without writing (CI mode)
ruff format --check src tests

# Type check
mypy src --ignore-missing-imports

# Run all pre-commit hooks against all files (useful before a PR)
pre-commit run --all-files
```

Pre-commit hooks run automatically on `git commit`:
- `trailing-whitespace`, `end-of-file-fixer`, `check-yaml/toml/json`
- `detect-private-key`, `check-added-large-files`
- `no-commit-to-branch` (blocks direct commits to `main` and `develop`)
- `ruff` lint + format
- `mypy`
- `bandit`
- `gitleaks`

---

## 8. Security Scans

### SAST — Bandit

```bash
pip install bandit[toml]
bandit -c pyproject.toml -r src
```

### Dependency CVE scan

```bash
pip install pip-audit
pip-audit
```

### Container scan — Trivy

```bash
# Build the image first
docker build -t poly-orchestrator:local --target production .

# Scan for HIGH and CRITICAL CVEs
trivy image --severity HIGH,CRITICAL poly-orchestrator:local
```

### Secret scanning — Gitleaks

```bash
# Install gitleaks (macOS)
brew install gitleaks

# Scan entire git history
gitleaks detect --source . -v
```

All four scans run in CI on every push to `main`/`develop` and nightly at 02:00 UTC. Results appear in **GitHub → Security → Code scanning alerts**.

---

## 9. Environment Variables Reference

Copy `.env.example` to `.env` and populate. Never commit `.env`.

| Variable | Default | Required | Description |
|---|---|---|---|
| `APP_ENV` | `development` | | `development` \| `staging` \| `production` |
| `APP_HOST` | `0.0.0.0` | | Bind address |
| `APP_PORT` | `8000` | | Bind port |
| `APP_LOG_LEVEL` | `INFO` | | `DEBUG` \| `INFO` \| `WARNING` \| `ERROR` |
| `APP_SECRET_KEY` | | Yes | Random 256-bit secret for internal signing |
| `DATABASE_URL` | | Yes | `postgresql+asyncpg://user:pass@host:5432/db` |
| `DATABASE_POOL_SIZE` | `10` | | SQLAlchemy pool size |
| `DATABASE_MAX_OVERFLOW` | `20` | | Pool overflow limit |
| `REDIS_URL` | | Yes | `redis://host:6379/0` |
| `CACHE_TTL_SECONDS` | `300` | | Cache expiry in seconds |
| `OPENAI_API_KEY` | | Yes* | OpenAI API key (`sk-…`) |
| `OPENAI_MODEL` | `gpt-4o` | | Model to use |
| `ANTHROPIC_API_KEY` | | Yes* | Anthropic API key (`sk-ant-…`) |
| `ANTHROPIC_MODEL` | `claude-sonnet-4-6` | | Model to use |
| `GOOGLE_API_KEY` | | Yes* | Google Generative AI key (`AIza…`) |
| `GOOGLE_MODEL` | `gemini-1.5-pro` | | Model to use |
| `PERPLEXITY_API_KEY` | | Yes* | Perplexity API key (`pplx-…`) |
| `PERPLEXITY_MODEL` | `sonar-pro` | | Model to use |
| `GROQ_API_KEY` | | Yes* | Groq API key (`gsk_…`) |
| `GROQ_MODEL` | `llama-3.3-70b-versatile` | | Model to use |
| `ENABLED_ADAPTERS` | `openai,anthropic,google,perplexity,groq` | | Comma-separated adapter list |
| `ORCHESTRATOR_TIMEOUT_SECONDS` | `30` | | Per-adapter HTTP timeout |
| `ORCHESTRATOR_MAX_CONCURRENCY` | `10` | | Max simultaneous adapter calls |
| `PROMETHEUS_ENABLED` | `true` | | Set `false` to disable `/metrics` |

> *\*Yes* means required if the adapter appears in `ENABLED_ADAPTERS`. Adapters with a blank key are silently skipped.

---

## 10. Adding a New AI Adapter

1. Create `src/poly_orchestrator/adapters/<name>_adapter.py`:

```python
from poly_orchestrator.adapters.base import AdapterResponse, BaseAdapter
from tenacity import retry, stop_after_attempt, wait_exponential
import httpx, time

class MyProviderAdapter(BaseAdapter):
    provider_name = "myprovider"
    _BASE_URL = "https://api.myprovider.com/v1/chat"

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=8))
    async def query(self, prompt: str) -> AdapterResponse:
        start = time.monotonic()
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            r = await client.post(
                self._BASE_URL,
                json={"prompt": prompt, "model": self.model},
                headers={"Authorization": f"Bearer {self.api_key}"},
            )
            r.raise_for_status()
            data = r.json()
        return AdapterResponse(
            provider=self.provider_name,
            model=self.model,
            content=data["text"],
            latency_ms=(time.monotonic() - start) * 1000,
        )
```

2. Register in `src/poly_orchestrator/adapters/__init__.py`:

```python
from poly_orchestrator.adapters.myprovider_adapter import MyProviderAdapter

ADAPTER_REGISTRY: dict[str, type[BaseAdapter]] = {
    ...
    "myprovider": MyProviderAdapter,
}
```

3. Add config fields in `src/poly_orchestrator/config.py`:

```python
myprovider_api_key: str = ""
myprovider_model: str = "best-model-v1"
```

4. Wire into the engine's `adapter_configs` dict in `orchestrator/engine.py`.

5. Add env vars to `.env.example`.

6. Add unit tests in `tests/unit/test_adapters.py`.

---

## 11. Production Kubernetes Deployment

### Prerequisites

- EKS cluster provisioned (see [Terraform section](#12-terraform--cloud-provisioning))
- `kubectl` configured: `aws eks update-kubeconfig --region us-east-1 --name poly-orchestrator-production`
- GHCR image pushed by CI

### First-time setup

```bash
# 1. Create namespace
kubectl apply -f infra/k8s/namespace.yaml

# 2. Create secrets (NEVER commit the real file)
kubectl create secret generic poly-orchestrator-secrets \
  --from-literal=DATABASE_URL='postgresql+asyncpg://poly:PASS@rds-endpoint:5432/poly_orchestrator' \
  --from-literal=REDIS_URL='redis://elasticache-endpoint:6379/0' \
  --from-literal=APP_SECRET_KEY='<random-256-bit>' \
  --from-literal=OPENAI_API_KEY='sk-...' \
  --from-literal=ANTHROPIC_API_KEY='sk-ant-...' \
  --from-literal=GOOGLE_API_KEY='AIza...' \
  --from-literal=PERPLEXITY_API_KEY='pplx-...' \
  --from-literal=GROQ_API_KEY='gsk_...' \
  -n poly-orchestrator

# 3. Apply all manifests
kubectl apply -f infra/k8s/

# 4. Run database migrations as a one-off Job
kubectl run migrate --image=ghcr.io/ayamigah16/poly-ochestrator-challenge:latest \
  --restart=Never --rm -it -n poly-orchestrator \
  --env-from=secret/poly-orchestrator-secrets \
  --env-from=configmap/poly-orchestrator-config \
  -- alembic upgrade head

# 5. Verify pods are healthy
kubectl get pods -n poly-orchestrator
kubectl describe pod -n poly-orchestrator -l app=poly-orchestrator
```

### Deploy a new image version

```bash
# Update the image tag in the deployment (or use Helm / ArgoCD)
kubectl set image deployment/poly-orchestrator \
  app=ghcr.io/ayamigah16/poly-ochestrator-challenge:v0.2.0 \
  -n poly-orchestrator

# Watch the rolling update
kubectl rollout status deployment/poly-orchestrator -n poly-orchestrator
```

### Roll back a bad deploy

```bash
# Instant rollback to previous revision
kubectl rollout undo deployment/poly-orchestrator -n poly-orchestrator

# Roll back to a specific revision
kubectl rollout history deployment/poly-orchestrator -n poly-orchestrator
kubectl rollout undo deployment/poly-orchestrator --to-revision=3 -n poly-orchestrator
```

### Scale manually

```bash
# Override HPA temporarily (HPA will reclaim control within minutes)
kubectl scale deployment/poly-orchestrator --replicas=5 -n poly-orchestrator
```

### View logs

```bash
# All pods, follow
kubectl logs -f -l app=poly-orchestrator -n poly-orchestrator

# Single pod
kubectl logs -f <pod-name> -n poly-orchestrator

# Last 100 lines
kubectl logs --tail=100 -l app=poly-orchestrator -n poly-orchestrator
```

### Exec into a pod

```bash
kubectl exec -it -n poly-orchestrator \
  $(kubectl get pod -n poly-orchestrator -l app=poly-orchestrator -o name | head -1) \
  -- /bin/sh
```

---

## 12. Terraform — Cloud Provisioning

### State backend (one-time, before first `terraform init`)

```bash
# Create S3 bucket for state
aws s3api create-bucket \
  --bucket poly-orchestrator-tf-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket poly-orchestrator-tf-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket poly-orchestrator-tf-state \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Create DynamoDB lock table
aws dynamodb create-table \
  --table-name poly-orchestrator-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### Plan and apply

```bash
cd infra/terraform

terraform init

# Dry run
terraform plan \
  -var="environment=production" \
  -var="db_password=$DB_PASSWORD" \
  -out=tfplan

# Review plan, then apply
terraform apply tfplan
```

### Destroy (non-production only)

```bash
terraform destroy \
  -var="environment=staging" \
  -var="db_password=$DB_PASSWORD"
```

> **Never run `destroy` against production without explicit approval.**

---

## 13. Monitoring & Alerting

### Grafana dashboard

Navigate to **http://localhost:3000** (local) or the Grafana ingress URL (prod).

Dashboard: **Poly Orchestrator — AI Visibility** (uid `poly-orchestrator-v1`)

Key panels:
- **Query Rate by Adapter** — healthy baseline is > 0 req/s when queries are being submitted
- **Latency p50/p95** — p95 > 10s indicates adapter timeout pressure
- **Brand Mention Rate** — the primary business KPI; thresholds: red < 0.3, yellow < 0.7, green ≥ 0.7
- **Adapter Errors last 1h** — any non-zero value warrants investigation

### Prometheus queries (useful ad-hoc)

```promql
# Error rate per adapter (last 5 min)
rate(orchestrator_adapter_errors_total[5m])

# 95th percentile latency per adapter
histogram_quantile(0.95,
  sum(rate(orchestrator_query_duration_seconds_bucket[5m])) by (le, adapter)
)

# Brand mention rate for a specific brand
orchestrator_brand_mention_rate{brand="Amalitec"}

# Total queries in last hour
increase(orchestrator_queries_total[1h])
```

### Suggested Alertmanager rules

```yaml
groups:
  - name: poly-orchestrator
    rules:
      - alert: AdapterHighErrorRate
        expr: rate(orchestrator_adapter_errors_total[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Adapter {{ $labels.adapter }} error rate elevated"

      - alert: BrandVisibilityLow
        expr: orchestrator_brand_mention_rate < 0.1
        for: 15m
        labels:
          severity: info
        annotations:
          summary: "Brand {{ $labels.brand }} mention rate critically low"

      - alert: HighLatency
        expr: >
          histogram_quantile(0.95,
            sum(rate(orchestrator_query_duration_seconds_bucket[5m])) by (le, adapter)
          ) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Adapter {{ $labels.adapter }} p95 latency > 10s"

      - alert: AppDown
        expr: up{job="poly-orchestrator"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Poly Orchestrator is down"
```

---

## 14. Release Process

### Triggering a release

CI/CD handles all release mechanics. To cut a release:

```bash
# On main branch, after all PRs are merged and CI is green
git checkout main
git pull origin main

# Tag with semantic version
git tag -a v0.2.0 -m "Release v0.2.0: add competitor trend chart"
git push origin v0.2.0
```

This triggers `release.yml` which:
1. Builds the production Docker image
2. Pushes with `v0.2.0`, `0.2`, and `latest` tags to GHCR
3. Generates a GitHub Release with changelog and image digest

### Checking the published image

```bash
docker pull ghcr.io/ayamigah16/poly-ochestrator-challenge:v0.2.0
docker run --rm ghcr.io/ayamigah16/poly-ochestrator-challenge:v0.2.0 --version
```

---

## 15. Incident Response Playbooks

### P1 — All adapters failing (0% mention rate, all requests 503)

1. Check `GET /health` — if 503, the app itself is down → check pod status
2. `kubectl get pods -n poly-orchestrator` — look for `CrashLoopBackOff` or `OOMKilled`
3. `kubectl logs -f -l app=poly-orchestrator -n poly-orchestrator` — look for startup errors
4. Verify secrets are present: `kubectl get secret poly-orchestrator-secrets -n poly-orchestrator`
5. Check Prometheus `orchestrator_adapter_errors_total` — is it one adapter or all?
6. If all: check whether `DATABASE_URL` or `REDIS_URL` are reachable from the pod
7. Roll back if a recent deploy caused the regression: `kubectl rollout undo deployment/poly-orchestrator -n poly-orchestrator`

---

### P2 — Single adapter degraded (partial results, errors on one provider)

1. Check `orchestrator_adapter_errors_total{adapter="openai"}` in Prometheus
2. Check the provider's status page:
   - OpenAI: https://status.openai.com
   - Anthropic: https://status.anthropic.com
   - Google: https://status.cloud.google.com
   - Perplexity: https://status.perplexity.ai
   - Groq: https://groqstatus.com
3. If the provider is down: remove it from `ENABLED_ADAPTERS` in the ConfigMap and restart pods
   ```bash
   kubectl edit configmap poly-orchestrator-config -n poly-orchestrator
   # change ENABLED_ADAPTERS to exclude the failing adapter
   kubectl rollout restart deployment/poly-orchestrator -n poly-orchestrator
   ```
4. Re-enable once the provider recovers

---

### P3 — Database connection exhausted

Symptom: `asyncpg.exceptions.TooManyConnectionsError` in logs.

1. Check current connections: `SELECT count(*) FROM pg_stat_activity WHERE datname='poly_orchestrator';`
2. If near limit, scale down app replicas temporarily: `kubectl scale deployment/poly-orchestrator --replicas=1 -n poly-orchestrator`
3. Review `DATABASE_POOL_SIZE` and `DATABASE_MAX_OVERFLOW` — reduce if needed
4. Consider adding a connection pooler (PgBouncer) in front of RDS

---

### P4 — Redis out of memory (OOM)

Symptom: `redis.exceptions.ResponseError: OOM command not allowed when used memory > 'maxmemory'`

1. Redis is configured with `allkeys-lru` eviction — OOM should be rare
2. Check memory: `redis-cli info memory | grep used_memory_human`
3. If Redis is truly full: `redis-cli flushdb` (clears cache; app continues with cold cache)
4. Increase `maxmemory` in `docker-compose.yml` or the ElastiCache node type

---

### P5 — High latency (p95 > 10s)

1. Check which adapter is slow: Prometheus → `histogram_quantile(0.95, …) by (adapter)`
2. Check `ORCHESTRATOR_TIMEOUT_SECONDS` — if it matches observed latency, the adapter is hitting the timeout and retrying
3. For chronically slow adapters: reduce `ORCHESTRATOR_TIMEOUT_SECONDS` to fail faster and surface partial results sooner
4. If all adapters are slow: check the pod's egress (NAT Gateway bandwidth, security group rules)

---

### P6 — Trivy/Bandit/CodeQL security alerts in GitHub

1. Navigate to **GitHub → Security → Code scanning alerts**
2. For Bandit: review `pyproject.toml` `[tool.bandit]` skips — only skip rules with documented justification
3. For Trivy: check if the CVE affects the code paths we use; if not, add it to a `.trivyignore` file with a comment
4. For pip-audit: upgrade the affected package (`pip install -e ".[dev]"` after bumping version in `pyproject.toml`)
5. For Gitleaks: if a false positive, add to `.gitleaks.toml`; if a real secret, rotate it immediately

---

## 16. CI/CD Reference

### Workflow triggers

| Workflow | File | Triggers |
|---|---|---|
| CI | `ci.yml` | Push to `main`, `develop`, `feature/**`; PR to `main`/`develop` |
| Security | `security.yml` | Push to `main`/`develop`; PR to `main`/`develop`; nightly 02:00 UTC |
| Release | `release.yml` | Push of tag matching `v*.*.*` |

### Required GitHub Secrets

| Secret | Used by |
|---|---|
| `GITHUB_TOKEN` | All workflows (auto-provided by Actions) |
| `CODECOV_TOKEN` | `ci.yml` — coverage upload |

### Skipping CI for a commit

Append `[skip ci]` to the commit message. Use only for documentation-only changes.

### Re-running a failed job

Go to **Actions → \<workflow run\> → Re-run failed jobs**. Do not re-run security workflows manually unless you have a specific reason — the nightly cron will catch it.

---

## 17. Common Commands Cheat-Sheet

```bash
# ── Local dev ──────────────────────────────────────────────────────────────────
pip install -e ".[dev]"                    # install with dev deps
uvicorn poly_orchestrator.main:app --reload  # run with hot-reload
pytest                                     # run all tests with coverage
pytest --no-cov -x                         # fast fail, no coverage
ruff check --fix src tests                 # lint + auto-fix
ruff format src tests                      # format
mypy src --ignore-missing-imports          # type check
pre-commit run --all-files                 # all hooks against all files

# ── Docker Compose ─────────────────────────────────────────────────────────────
docker compose up -d                       # full stack in background
docker compose up -d postgres redis        # backing services only
docker compose logs -f app                 # follow app logs
docker compose down                        # stop all services
docker compose down -v                     # stop + delete volumes

# ── Database ────────────────────────────────────────────────────────────────────
alembic upgrade head                       # apply all migrations
alembic downgrade -1                       # roll back one
alembic current                            # show current revision
alembic history --verbose                  # full migration history

# ── Security ────────────────────────────────────────────────────────────────────
bandit -c pyproject.toml -r src            # SAST scan
pip-audit                                  # CVE scan
trivy image poly-orchestrator:local        # container scan
gitleaks detect --source . -v             # secret scan

# ── Kubernetes ──────────────────────────────────────────────────────────────────
kubectl get pods -n poly-orchestrator                  # pod list
kubectl logs -f -l app=poly-orchestrator -n poly-orchestrator  # logs
kubectl rollout status deployment/poly-orchestrator -n poly-orchestrator
kubectl rollout undo deployment/poly-orchestrator -n poly-orchestrator
kubectl describe pod -n poly-orchestrator <pod-name>
kubectl top pods -n poly-orchestrator                  # resource usage

# ── Terraform ───────────────────────────────────────────────────────────────────
cd infra/terraform
terraform init                             # initialise providers + backend
terraform plan -var="environment=staging" -var="db_password=$PW"
terraform apply tfplan
terraform output                           # show outputs (e.g. RDS endpoint)

# ── Git workflow ─────────────────────────────────────────────────────────────────
git checkout -b feature/<name> develop     # new feature branch
git push -u origin feature/<name>          # push to remote
# open PR → develop → squash merge → delete branch
# develop → main via PR on release day, then tag v*.*.* to trigger release
```
