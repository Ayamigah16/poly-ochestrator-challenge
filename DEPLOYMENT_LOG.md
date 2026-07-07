# Deployment Log — Poly Orchestrator

End-to-end deployment record covering Docker Compose local stack and Kubernetes (kind) cluster.
Documents every issue encountered and the exact fix applied.

---

## Environment

| Item | Detail |
| --- | --- |
| OS | Ubuntu / WSL2 (Linux 6.18 on Windows) |
| Docker | Docker Desktop with BuildKit |
| Kubernetes | kind v0.22.0 → cluster `kind-devsecops-lab` (k8s v1.29.2) |
| Python | 3.11 (venv) |
| AI provider key | Mistral only (`ENABLED_ADAPTERS=mistral`) |

---

## Phase 1 — Docker Compose Stack

### Issue 1 · `alembic: executable file not found in $PATH`

**Symptom**
```
exec: "alembic": executable file not found in $PATH
```
`docker compose run --rm migrate` failed immediately.

**Root cause**
The original Dockerfile used a broken multi-stage pattern:
```dockerfile
# Builder stage
pip install --no-cache-dir --target /build/site-packages -e .
# Production stage
COPY --from=builder /build/site-packages /usr/local/lib/python3.11/site-packages
pip install alembic uvicorn ...   # pip sees dist-info → "already satisfied" → no scripts created
```
`pip install --target -e .` (editable + target) is unsupported in modern pip. The target directory was effectively empty, so the production stage's `pip install` found nothing to skip — but even when it did install, it never created `/usr/local/bin/alembic` because dist-info from the COPY confused it.

**Fix**
Rewrote to a single-stage Dockerfile with a clean `pip install .`:
```dockerfile
FROM python:3.11-slim
RUN apt-get install gcc libpq-dev libpq5 curl ...
COPY pyproject.toml README.md ./
COPY src/ src/
RUN pip install --upgrade pip && pip install --no-cache-dir .
CMD ["python", "-m", "uvicorn", ...]
```
Also changed `docker-compose.yml` migrate command to `python -m alembic upgrade head` (module invocation bypasses PATH entirely).

---

### Issue 2 · BuildKit persistent cache served stale layers despite `--no-cache`

**Symptom**
After rewriting the Dockerfile the production-stage steps never appeared in build output; `No module named alembic` persisted.

**Root cause**
BuildKit maintains a persistent layer cache on disk. Even `docker compose build --no-cache` did not invalidate it for the production stage because the base image digest matched a cached entry.

**Fix**
```bash
docker builder prune -f   # flush BuildKit's on-disk cache
```
Then rebuild with `--rebuild`.

---

### Issue 3 · `target stage "builder" could not be found`

**Symptom**
```
failed to solve: target stage "builder" could not be found
```
After removing multi-stage, the build still failed.

**Root cause**
`docker-compose.override.yml` (auto-merged by Docker Compose) contained:
```yaml
services:
  app:
    build:
      target: builder   # ← referenced a stage that no longer exists
    command:
      - uvicorn         # ← binary not in PATH
```

**Fix**
Removed `target: builder`, changed command to `python -m uvicorn`:
```yaml
services:
  app:
    command:
      - python
      - -m
      - uvicorn
      - poly_orchestrator.main:app
      - --reload
```

---

### Issue 4 · `DuplicateTableError: relation "ix_query_records_brand" already exists`

**Symptom**
Migration failed on first run against a fresh database.

**Root cause**
`migrations/versions/001_initial_schema.py` created the same index twice:
```python
op.create_table("query_records",
    sa.Column("brand", ..., index=True),  # ← auto-creates ix_query_records_brand
    ...
)
op.create_index("ix_query_records_brand", "query_records", ["brand"])  # ← duplicate
```
`index=True` on a column inside `op.create_table` instructs SQLAlchemy to create the index during table creation. The subsequent explicit `op.create_index` call then collides with it.

**Fix**
Removed `index=True` from both `brand` columns (in `query_records` and `brand_metrics`), keeping only the explicit `op.create_index` calls.

---

### Result — Docker Compose stack

```
{
  "status": "ok",
  "version": "0.1.0",
  "database": "ok",
  "redis": "ok",
  "adapters_configured": ["mistral"]
}
```

All 5 services healthy: `poly_app`, `poly_postgres`, `poly_redis`, `poly_prometheus`, `poly_grafana`.

---

## Phase 2 — Kubernetes Deployment (kind)

### Screenshot evidence

| # | Screenshot | What it shows |
| --- | --- | --- |
| 1 | `screenshots/Screenshot 2026-07-07 100930.png` | `kind create cluster --name devsecops-lab` — all 5 setup steps ✓ |
| 2 | `screenshots/Screenshot 2026-07-07 101001.png` | `kind load docker-image` + `kubectl create secret` — image loaded into cluster, secret created |
| 3 | `screenshots/Screenshot 2026-07-07 101017.png` | `./scripts/k8s-deploy.sh` — all manifests applied, then `--env-from` error (fixed in next iteration) |

---

### Issue 5 · No postgres/redis manifests for in-cluster use

**Root cause**
The original `infra/k8s/` manifests assumed external managed databases (AWS RDS + ElastiCache). A kind cluster has no such services.

**Fix**
Added `infra/k8s/postgres.yaml` and `infra/k8s/redis.yaml` — standard Deployment + Service + PVC manifests. Updated `scripts/k8s-deploy.sh` MANIFESTS list to include them (applied before the app deployment).

Secret values point to in-cluster service names:
```
DATABASE_URL=postgresql+asyncpg://poly:poly_pass@postgres:5432/poly_orchestrator
REDIS_URL=redis://redis:6379/0
```

---

### Issue 6 · `kubectl run --env-from` unknown flag

**Symptom**
```
error: unknown flag: --env-from
```

**Root cause**
`kubectl run` does not support `--env-from`. The flag only exists in pod/deployment YAML specs.

**Fix**
Replaced `kubectl run` with `kubectl apply -f -` piping a full pod manifest:
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: migrate-job
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: migrate
      image: ${MIGRATE_IMAGE}
      command: ["python", "-m", "alembic", "upgrade", "head"]
      envFrom:
        - secretRef:
            name: poly-orchestrator-secrets
        - configMapRef:
            name: poly-orchestrator-config
EOF
```

---

### Issue 7 · `kubectl wait --for=condition=Succeeded` times out forever

**Symptom**
```
error: timed out waiting for the condition on pods/migrate-job
```
The migration ran fine (alembic logs showed it connecting and starting) but the wait never resolved.

**Root cause**
Kubernetes pods do not have a `Succeeded` condition in `.status.conditions`. The wait was looking for a condition that never gets added. Only `batch/v1 Job` resources have `Complete` and `Failed` conditions that `kubectl wait` can observe.

**Fix**
Changed the migration resource from a raw Pod to a Kubernetes Job:
```yaml
apiVersion: batch/v1
kind: Job
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers: [...]
```
Wait command:
```bash
kubectl wait job/migrate-job --for=condition=Complete --timeout=120s -n "$NAMESPACE"
```

---

### Issue 8 · `imagePullPolicy: Always` with a local kind image

**Root cause**
`deployment.yaml` had `imagePullPolicy: Always` and `image: ghcr.io/ayamigah16/...`. kind clusters cannot pull from ghcr.io without a published image.

**Fix**
- Changed `imagePullPolicy: Always` → `IfNotPresent`
- Loaded the local image into the cluster: `kind load docker-image poly-orchestrator:local --name devsecops-lab`
- Deployed with `--image poly-orchestrator:local` flag

---

### Result — Kubernetes stack

```
kubectl get pods -n poly-orchestrator

NAME                                 READY   STATUS    RESTARTS   AGE
poly-orchestrator-656b5f78bf-9lw8s   1/1     Running   0          17m
poly-orchestrator-656b5f78bf-9n96g   1/1     Running   0          17m
```

Health check via port-forward:
```json
{
  "status": "ok",
  "version": "0.1.0",
  "database": "ok",
  "redis": "ok",
  "adapters_configured": ["mistral"]
}
```

Deployed 2 replicas with zero-downtime rolling update (`maxUnavailable: 0`), HPA, NetworkPolicy, and Ingress all applied.

---

## Files Changed in This Session

| File | Change |
| --- | --- |
| `Dockerfile` | Rewrote from broken multi-stage to clean single-stage `pip install .` |
| `docker-compose.yml` | Removed `target: production`; migrate command → `python -m alembic upgrade head` |
| `docker-compose.override.yml` | Removed `target: builder`; fixed uvicorn command |
| `migrations/versions/001_initial_schema.py` | Removed duplicate `index=True` from `brand` columns |
| `src/poly_orchestrator/adapters/mistral_adapter.py` | New — Mistral AI provider (6th adapter) |
| `src/poly_orchestrator/adapters/__init__.py` | Registered `MistralAdapter` |
| `src/poly_orchestrator/config.py` | Added `mistral_api_key`, `mistral_model` settings |
| `src/poly_orchestrator/orchestrator/engine.py` | Added Mistral to `adapter_configs` |
| `infra/k8s/postgres.yaml` | New — in-cluster PostgreSQL for kind |
| `infra/k8s/redis.yaml` | New — in-cluster Redis for kind |
| `infra/k8s/configmap.yaml` | Added `MISTRAL_MODEL`; set `ENABLED_ADAPTERS=mistral` |
| `infra/k8s/deployment.yaml` | Changed `imagePullPolicy: Always` → `IfNotPresent` |
| `scripts/k8s-deploy.sh` | Added postgres/redis to manifest list; fixed migrate: Pod→Job; `--env-from` → inline YAML |
| `scripts/` (all 8 scripts) | New — full deployment automation suite |
| `.env.example` | Added Mistral vars; removed invalid `PROMETHEUS_PORT` |
