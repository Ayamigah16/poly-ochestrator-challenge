#!/usr/bin/env bash
# Bootstrap an EKS cluster after terraform-apply.sh --platform eks:
#   1. Configure kubectl (aws eks update-kubeconfig)
#   2. Look up the ElastiCache Redis endpoint
#   3. Create the poly-orchestrator namespace (idempotent)
#   4. Create / replace the poly-orchestrator-secrets k8s Secret
#   5. Call k8s-deploy.sh to apply manifests and roll out the app
#
# Usage:
#   ./scripts/eks-bootstrap.sh --env staging --image <ecr-url>:latest
#   ./scripts/eks-bootstrap.sh --env staging --image <ecr-url>:latest --skip-deploy
#   ./scripts/eks-bootstrap.sh --env staging --skip-deploy   # secret setup only
#
# Credentials are read from env vars (or prompted interactively if unset):
#   DB_PASSWORD        RDS / postgres container password
#   APP_SECRET_KEY     FastAPI secret key
#   MISTRAL_API_KEY    Mistral AI key
#
# Optional provider keys (omit any you do not use):
#   OPENAI_API_KEY  ANTHROPIC_API_KEY  GOOGLE_API_KEY
#   PERPLEXITY_API_KEY  GROQ_API_KEY

source "$(dirname "$0")/lib.sh"

ENVIRONMENT=""
IMAGE=""
SKIP_DEPLOY=false
REGION="eu-west-1"
NAMESPACE="poly-orchestrator"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)         ENVIRONMENT="$2"; shift 2 ;;
    --image)       IMAGE="$2";       shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    --namespace)   NAMESPACE="$2";   shift 2 ;;
    --skip-deploy) SKIP_DEPLOY=true; shift   ;;
    --help|-h)
      grep '^#' "$0" | head -20 | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown argument: $1 — run with --help for usage" ;;
  esac
done

[[ -z "$ENVIRONMENT" ]] && die "--env is required (development | staging | production)"

CLUSTER_NAME="poly-orchestrator-${ENVIRONMENT}"
CACHE_CLUSTER_ID="poly-eks-${ENVIRONMENT}"

require aws kubectl

# ── AWS identity ───────────────────────────────────────────────────────────────
step "AWS identity"
CALLER=$(aws sts get-caller-identity --output json)
info "Account: $(echo "$CALLER" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Account"])')"
info "ARN:     $(echo "$CALLER" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Arn"])')"
info "Cluster: $CLUSTER_NAME  (region: $REGION)"
echo ""

# ── 1. Configure kubectl ───────────────────────────────────────────────────────
step "Configuring kubectl"
aws eks update-kubeconfig \
  --region "$REGION" \
  --name  "$CLUSTER_NAME"
success "kubectl context: $(kubectl config current-context)"

# ── 2. Look up Redis endpoint ──────────────────────────────────────────────────
step "Looking up ElastiCache Redis endpoint"
REDIS_HOST=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id "$CACHE_CLUSTER_ID" \
  --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' \
  --output text \
  --region "$REGION" 2>/dev/null || true)

if [[ -z "$REDIS_HOST" || "$REDIS_HOST" == "None" ]]; then
  warn "Could not resolve Redis endpoint automatically."
  read -r -p "$(echo -e "${YELLOW}Enter Redis host (hostname only, no port): ${RESET}")" REDIS_HOST
fi
[[ -z "$REDIS_HOST" ]] && die "Redis host is required"
REDIS_URL="redis://${REDIS_HOST}:6379/0"
success "Redis: $REDIS_URL"

# ── 3. Collect credentials ─────────────────────────────────────────────────────
step "Credentials"

prompt_secret() {
  local var="$1" label="$2"
  if [[ -z "${!var:-}" ]]; then
    read -r -s -p "$(echo -e "${YELLOW}Enter ${label}: ${RESET}")" val && echo ""
    eval "${var}=\"${val}\""
  else
    info "$label: (from environment)"
  fi
}

prompt_secret DB_PASSWORD        "DB password"
prompt_secret APP_SECRET_KEY     "APP_SECRET_KEY"
prompt_secret MISTRAL_API_KEY    "MISTRAL_API_KEY"

DATABASE_URL="postgresql+asyncpg://poly:${DB_PASSWORD}@postgres.${NAMESPACE}.svc.cluster.local:5432/poly_orchestrator"

# ── 4. Namespace ───────────────────────────────────────────────────────────────
step "Namespace"
kubectl apply -f "$REPO_ROOT/infra/k8s/namespace.yaml"
success "Namespace '$NAMESPACE' ready"

# ── 5. Create / replace k8s Secret ────────────────────────────────────────────
step "k8s Secret — poly-orchestrator-secrets"

SECRET_ARGS=(
  --from-literal="DATABASE_URL=${DATABASE_URL}"
  --from-literal="REDIS_URL=${REDIS_URL}"
  --from-literal="APP_SECRET_KEY=${APP_SECRET_KEY}"
  --from-literal="MISTRAL_API_KEY=${MISTRAL_API_KEY}"
  --from-literal="DB_PASSWORD=${DB_PASSWORD}"
)

# Append optional provider keys when present in the environment
for pair in \
  "OPENAI_API_KEY=OPENAI_API_KEY" \
  "ANTHROPIC_API_KEY=ANTHROPIC_API_KEY" \
  "GOOGLE_API_KEY=GOOGLE_API_KEY" \
  "PERPLEXITY_API_KEY=PERPLEXITY_API_KEY" \
  "GROQ_API_KEY=GROQ_API_KEY"; do
  env_var="${pair%%=*}"
  k8s_key="${pair##*=}"
  if [[ -n "${!env_var:-}" ]]; then
    SECRET_ARGS+=(--from-literal="${k8s_key}=${!env_var}")
    info "Including ${k8s_key}"
  fi
done

# Delete first so we can re-create cleanly (handles key rotation too)
kubectl delete secret poly-orchestrator-secrets \
  -n "$NAMESPACE" --ignore-not-found

kubectl create secret generic poly-orchestrator-secrets \
  -n "$NAMESPACE" \
  "${SECRET_ARGS[@]}"

success "Secret created"

# ── 6. Deploy ──────────────────────────────────────────────────────────────────
if [[ "$SKIP_DEPLOY" == "false" ]]; then
  step "Deploying application"
  DEPLOY_ARGS=(--namespace "$NAMESPACE")
  [[ -n "$IMAGE" ]] && DEPLOY_ARGS+=(--image "$IMAGE")

  "$REPO_ROOT/scripts/k8s-deploy.sh" "${DEPLOY_ARGS[@]}"
else
  info "Skipping deploy (--skip-deploy set)"
  echo ""
  echo "  Run deploy manually:"
  [[ -n "$IMAGE" ]] \
    && echo "    ./scripts/k8s-deploy.sh --image $IMAGE" \
    || echo "    ./scripts/k8s-deploy.sh --image <ecr-url>:latest"
fi

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  EKS bootstrap complete!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Cluster:      $CLUSTER_NAME"
echo "  Namespace:    $NAMESPACE"
echo "  Logs:         kubectl logs -f -l app=poly-orchestrator -n $NAMESPACE"
echo "  Port-forward: kubectl port-forward svc/poly-orchestrator 8000:80 -n $NAMESPACE"
echo "  Rollback:     ./scripts/k8s-rollback.sh"
echo ""
