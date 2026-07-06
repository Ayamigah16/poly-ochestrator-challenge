#!/usr/bin/env bash
# End-to-end smoke test: hit /health and POST a real query.
# Runs after any deploy to verify the service is actually working.
#
# Usage:
#   ./scripts/smoke-test.sh                          # defaults to localhost:8000
#   ./scripts/smoke-test.sh --url https://api.prod.example.com
#   ./scripts/smoke-test.sh --brand "Amalitec" --adapters openai
#   ./scripts/smoke-test.sh --url http://localhost:8000 --verbose

source "$(dirname "$0")/lib.sh"

BASE_URL="http://localhost:8000"
BRAND="Amalitec"
ADAPTERS="openai"
VERBOSE=false
PASS=0
FAIL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)      BASE_URL="$2";  shift 2 ;;
    --brand)    BRAND="$2";     shift 2 ;;
    --adapters) ADAPTERS="$2";  shift 2 ;;
    --verbose)  VERBOSE=true;   shift   ;;
    --help|-h)
      grep '^#' "$0" | head -8 | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require curl python3

_pass() { PASS=$((PASS+1)); success "$1"; }
_fail() { FAIL=$((FAIL+1)); error  "$1"; }

_json() {
  local raw="$1" key="$2"
  echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d$key)" 2>/dev/null || echo ""
}

_pretty() {
  [[ "$VERBOSE" == "true" ]] && echo "$1" | python3 -m json.tool 2>/dev/null || true
}

echo ""
info "Target: $BASE_URL"
echo ""

# ── Test 1: /health ────────────────────────────────────────────────────────────
step "Test 1 — GET /health"
HEALTH_RAW=$(curl -sf --max-time 10 "$BASE_URL/health" 2>/dev/null || echo '{}')
_pretty "$HEALTH_RAW"

STATUS=$(_json "$HEALTH_RAW" "['status']")
if [[ "$STATUS" == "ok" ]]; then
  _pass "/health → status: ok"
else
  _fail "/health returned status='$STATUS' (expected 'ok')"
fi

DB=$(_json "$HEALTH_RAW" "['database']")
if [[ "$DB" == "ok" ]]; then
  _pass "/health → database: ok"
else
  warn "/health → database: '$DB' (may be expected in local-only mode)"
fi

REDIS=$(_json "$HEALTH_RAW" "['redis']")
if [[ "$REDIS" == "ok" ]]; then
  _pass "/health → redis: ok"
else
  warn "/health → redis: '$REDIS' (may be expected in local-only mode)"
fi

# ── Test 2: /metrics ──────────────────────────────────────────────────────────
step "Test 2 — GET /metrics"
METRICS_STATUS=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/metrics")
if [[ "$METRICS_STATUS" == "200" ]]; then
  _pass "/metrics → HTTP 200"
  if [[ "$VERBOSE" == "true" ]]; then
    curl -sf "$BASE_URL/metrics" | head -20
  fi
elif [[ "$METRICS_STATUS" == "404" ]]; then
  warn "/metrics → 404 (PROMETHEUS_ENABLED may be false — not a failure)"
else
  _fail "/metrics → HTTP $METRICS_STATUS"
fi

# ── Test 3: /docs reachable ────────────────────────────────────────────────────
step "Test 3 — GET /docs"
DOCS_STATUS=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/docs")
if [[ "$DOCS_STATUS" == "200" ]]; then
  _pass "/docs → HTTP 200 (Swagger UI serving)"
else
  _fail "/docs → HTTP $DOCS_STATUS"
fi

# ── Test 4: POST /api/v1/queries ───────────────────────────────────────────────
step "Test 4 — POST /api/v1/queries"
QUERY_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'brand': '$BRAND',
  'query_template': 'What do you know about {brand}?',
  'adapters': ['$ADAPTERS'],
  'competitors': []
}))
")

QUERY_RAW=$(curl -sf --max-time 60 \
  -X POST "$BASE_URL/api/v1/queries" \
  -H "Content-Type: application/json" \
  -d "$QUERY_PAYLOAD" 2>/dev/null || echo '{}')
_pretty "$QUERY_RAW"

Q_STATUS=$(_json "$QUERY_RAW" "['status']")
if [[ "$Q_STATUS" == "ok" ]]; then
  _pass "POST /api/v1/queries → status: ok"
elif [[ "$Q_STATUS" == "partial" ]]; then
  warn "POST /api/v1/queries → status: partial (some adapters failed — check API keys)"
elif echo "$QUERY_RAW" | grep -q "503"; then
  warn "POST /api/v1/queries → 503 (no adapters configured — expected if no API keys set)"
else
  _fail "POST /api/v1/queries → unexpected response (status='$Q_STATUS')"
fi

MENTION_RATE=$(_json "$QUERY_RAW" "['mention_rate']")
[[ -n "$MENTION_RATE" ]] && info "  mention_rate:     $MENTION_RATE"
SUCCEEDED=$(_json "$QUERY_RAW" "['succeeded_adapters']")
[[ -n "$SUCCEEDED" ]] && info "  succeeded_adapters: $SUCCEEDED"
FAILED=$(_json "$QUERY_RAW" "['failed_adapters']")
[[ -n "$FAILED" && "$FAILED" != "[]" ]] && warn "  failed_adapters:  $FAILED"

# ── Test 5: 404 on unknown path ────────────────────────────────────────────────
step "Test 5 — 404 on unknown route"
NOT_FOUND=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/this-does-not-exist")
if [[ "$NOT_FOUND" == "404" ]]; then
  _pass "Unknown route returns 404 (not 500)"
else
  _fail "Unknown route returned HTTP $NOT_FOUND (expected 404)"
fi

# ── Results ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Smoke Test Results${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${GREEN}Passed: $PASS${RESET}"
[[ $FAIL -gt 0 ]] && echo -e "  ${RED}Failed: $FAIL${RESET}" || echo -e "  ${GREEN}Failed: $FAIL${RESET}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  error "Smoke test FAILED — $FAIL check(s) did not pass"
  echo "  Check logs: docker compose logs -f app"
  echo "              kubectl logs -f -l app=poly-orchestrator -n poly-orchestrator"
  exit 1
else
  success "All smoke tests passed — $BASE_URL is healthy"
fi
