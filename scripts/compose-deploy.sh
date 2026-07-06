#!/usr/bin/env bash
# Deploy the full Docker Compose stack: build → migrate → start → health-check.
# Suitable for local development and single-server staging environments.
#
# Usage:
#   ./scripts/compose-deploy.sh                # full deploy (default)
#   ./scripts/compose-deploy.sh --rebuild      # force image rebuild
#   ./scripts/compose-deploy.sh --down         # tear down the stack
#   ./scripts/compose-deploy.sh --logs         # follow logs after deploy
#   ./scripts/compose-deploy.sh --no-monitoring  # skip prometheus + grafana

source "$(dirname "$0")/lib.sh"

REBUILD=false
TEARDOWN=false
FOLLOW_LOGS=false
NO_MONITORING=false

for arg in "$@"; do
  case "$arg" in
    --rebuild)       REBUILD=true       ;;
    --down)          TEARDOWN=true      ;;
    --logs)          FOLLOW_LOGS=true   ;;
    --no-monitoring) NO_MONITORING=true ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
  esac
done

require docker git

cd "$REPO_ROOT"

[[ -f .env ]] || die ".env not found — run ./scripts/setup-local.sh first or cp .env.example .env"

# ── Tear down ──────────────────────────────────────────────────────────────────
if [[ "$TEARDOWN" == "true" ]]; then
  step "Tearing down the stack"
  confirm "This will stop all containers. Data volumes are preserved. Continue?"
  docker compose down --remove-orphans
  success "Stack stopped"
  exit 0
fi

# ── Build ──────────────────────────────────────────────────────────────────────
step "Building application image"
if [[ "$REBUILD" == "true" ]]; then
  docker compose build --no-cache app
else
  docker compose build app
fi
success "Image built: poly-orchestrator:local"

# ── Start backing services ─────────────────────────────────────────────────────
step "Starting postgres + redis"
docker compose up -d postgres redis

info "Waiting for postgres to be healthy..."
for ((i=1; i<=30; i++)); do
  if docker compose exec -T postgres pg_isready -U poly -d poly_orchestrator &>/dev/null; then
    success "PostgreSQL ready"
    break
  fi
  [[ $i -eq 30 ]] && die "PostgreSQL did not become ready in 60s"
  sleep 2
done

info "Waiting for redis to be healthy..."
for ((i=1; i<=15; i++)); do
  if docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
    success "Redis ready"
    break
  fi
  [[ $i -eq 15 ]] && die "Redis did not become ready in 30s"
  sleep 2
done

# ── Migrations ─────────────────────────────────────────────────────────────────
step "Running database migrations"
docker compose run --rm migrate
success "Migrations applied"

# ── Start application ──────────────────────────────────────────────────────────
step "Starting application"
docker compose up -d app

# ── Start monitoring (optional) ────────────────────────────────────────────────
if [[ "$NO_MONITORING" == "false" ]]; then
  step "Starting monitoring stack (prometheus + grafana)"
  docker compose up -d prometheus grafana
fi

# ── Health check ───────────────────────────────────────────────────────────────
step "Health check"
wait_for_http "http://localhost:8000/health" 30 3

HEALTH=$(curl -sf http://localhost:8000/health)
echo "$HEALTH" | python3 -m json.tool 2>/dev/null || echo "$HEALTH"

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Stack deployed successfully!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  API:        http://localhost:8000"
echo "  Swagger UI: http://localhost:8000/docs"
echo "  Health:     http://localhost:8000/health"
echo "  Metrics:    http://localhost:8000/metrics"
if [[ "$NO_MONITORING" == "false" ]]; then
  echo "  Prometheus: http://localhost:9090"
  echo "  Grafana:    http://localhost:3000  (admin / admin)"
fi
echo ""
echo -e "  Running containers:"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
echo ""

if [[ "$FOLLOW_LOGS" == "true" ]]; then
  step "Following logs (Ctrl+C to stop)"
  docker compose logs -f app
fi
