#!/usr/bin/env bash
# Bootstrap a complete local development environment from scratch.
# Safe to re-run — every step is idempotent.
#
# Usage:
#   ./scripts/setup-local.sh
#   ./scripts/setup-local.sh --skip-services   # skip Docker backing services
#   ./scripts/setup-local.sh --skip-migrate    # skip alembic upgrade head

source "$(dirname "$0")/lib.sh"

SKIP_SERVICES=false
SKIP_MIGRATE=false
for arg in "$@"; do
  case "$arg" in
    --skip-services) SKIP_SERVICES=true ;;
    --skip-migrate)  SKIP_MIGRATE=true  ;;
    --help|-h)
      echo "Usage: $0 [--skip-services] [--skip-migrate]"
      exit 0 ;;
  esac
done

require python3 git docker pip

cd "$REPO_ROOT"

# ── 1. Python virtualenv ───────────────────────────────────────────────────────
step "Python virtual environment"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
  success "Created .venv"
else
  info ".venv already exists — skipping creation"
fi

# shellcheck disable=SC1091
source .venv/bin/activate
success "Activated .venv ($(python --version))"

# ── 2. Install dependencies ────────────────────────────────────────────────────
step "Installing Python dependencies"
pip install --quiet --upgrade pip
pip install --quiet -e ".[dev]"
success "Dependencies installed"

# ── 3. Environment file ────────────────────────────────────────────────────────
step "Environment file"
if [[ ! -f .env ]]; then
  cp .env.example .env
  warn ".env created from .env.example — fill in your API keys before running the app"
  warn "  \$EDITOR .env"
else
  success ".env already exists"
fi

# ── 4. Pre-commit hooks ────────────────────────────────────────────────────────
step "Pre-commit hooks"
if ! pre-commit --version &>/dev/null; then
  die "pre-commit not found after install — check the [dev] extras in pyproject.toml"
fi
pre-commit install --install-hooks -q
success "Pre-commit hooks installed"

# ── 5. Backing services ────────────────────────────────────────────────────────
if [[ "$SKIP_SERVICES" == "false" ]]; then
  step "Starting backing services (postgres + redis)"
  require docker
  docker compose up -d postgres redis
  info "Waiting for postgres to be healthy..."
  for ((i=1; i<=20; i++)); do
    if docker compose exec -T postgres pg_isready -U poly -d poly_orchestrator &>/dev/null; then
      success "PostgreSQL is ready"
      break
    fi
    [[ $i -eq 20 ]] && die "PostgreSQL did not become ready in time"
    sleep 2
  done
fi

# ── 6. Database migrations ─────────────────────────────────────────────────────
if [[ "$SKIP_MIGRATE" == "false" ]]; then
  step "Running database migrations"
  alembic upgrade head
  success "Migrations applied ($(alembic current 2>&1 | tail -1))"
fi

# ── 7. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Local environment ready!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Start the app:"
echo "    source .venv/bin/activate"
echo "    uvicorn poly_orchestrator.main:app --reload --host 0.0.0.0 --port 8000"
echo ""
echo "  API docs: http://localhost:8000/docs"
echo "  Health:   http://localhost:8000/health"
echo ""
