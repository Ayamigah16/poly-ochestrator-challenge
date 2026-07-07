#!/usr/bin/env bash
# Deploy or update the application on a Kubernetes cluster.
# Handles first-time setup and rolling updates identically.
#
# Usage:
#   ./scripts/k8s-deploy.sh --image ghcr.io/ayamigah16/poly-ochestrator-challenge:v0.2.0
#   ./scripts/k8s-deploy.sh --image <tag> --skip-migrate   # skip alembic job
#   ./scripts/k8s-deploy.sh --dry-run                      # kubectl --dry-run only
#
# Prerequisites:
#   kubectl configured against the target cluster
#   kubectl create secret ... poly-orchestrator-secrets (see RUNBOOK.md §11)

source "$(dirname "$0")/lib.sh"

NAMESPACE="poly-orchestrator"
IMAGE=""
SKIP_MIGRATE=false
DRY_RUN=false
TIMEOUT="300s"

usage() {
  grep '^#' "$0" | head -20 | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)        IMAGE="$2";         shift 2 ;;
    --namespace)    NAMESPACE="$2";     shift 2 ;;
    --timeout)      TIMEOUT="$2";       shift 2 ;;
    --skip-migrate) SKIP_MIGRATE=true;  shift   ;;
    --dry-run)      DRY_RUN=true;       shift   ;;
    --help|-h)      usage ;;
    *) die "Unknown argument: $1 — run with --help for usage" ;;
  esac
done

require kubectl

cd "$REPO_ROOT"

DRY_FLAG=""
[[ "$DRY_RUN" == "true" ]] && DRY_FLAG="--dry-run=client"

info "Target cluster:    $(kubectl config current-context)"
info "Target namespace:  $NAMESPACE"
[[ -n "$IMAGE" ]] && info "Image:             $IMAGE"
[[ "$DRY_RUN" == "true" ]] && warn "DRY RUN — no changes will be applied"
echo ""

# ── 1. Namespace ───────────────────────────────────────────────────────────────
step "Namespace"
kubectl apply $DRY_FLAG -f infra/k8s/namespace.yaml
success "Namespace '$NAMESPACE' ready"

# ── 2. Verify secrets exist ────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
  step "Secret check"
  if ! kubectl get secret poly-orchestrator-secrets -n "$NAMESPACE" &>/dev/null; then
    error "Secret 'poly-orchestrator-secrets' not found in namespace '$NAMESPACE'"
    echo ""
    echo "  Create it with:"
    echo "    kubectl create secret generic poly-orchestrator-secrets \\"
    echo "      --from-literal=DATABASE_URL='postgresql+asyncpg://...' \\"
    echo "      --from-literal=REDIS_URL='redis://...' \\"
    echo "      --from-literal=APP_SECRET_KEY='...' \\"
    echo "      --from-literal=MISTRAL_API_KEY='...' \\"
    echo "      -n $NAMESPACE"
    echo ""
    echo "  (Add any other provider keys you have: OPENAI_API_KEY, ANTHROPIC_API_KEY, etc.)"
    exit 1
  fi
  success "Secret 'poly-orchestrator-secrets' found"
fi

# ── 3. Apply all manifests ─────────────────────────────────────────────────────
step "Applying Kubernetes manifests"
MANIFESTS=(
  infra/k8s/namespace.yaml
  infra/k8s/postgres.yaml
  infra/k8s/redis.yaml
  infra/k8s/configmap.yaml
  infra/k8s/service.yaml
  infra/k8s/deployment.yaml
  infra/k8s/hpa.yaml
  infra/k8s/ingress.yaml
)
for manifest in "${MANIFESTS[@]}"; do
  if [[ -f "$manifest" ]]; then
    kubectl apply $DRY_FLAG -f "$manifest"
    success "Applied $manifest"
  else
    warn "Skipping $manifest (file not found)"
  fi
done

# ── 4. Update image tag (if supplied) ─────────────────────────────────────────
if [[ -n "$IMAGE" ]]; then
  step "Updating deployment image to $IMAGE"
  kubectl set image $DRY_FLAG \
    deployment/poly-orchestrator \
    app="$IMAGE" \
    -n "$NAMESPACE"
  success "Image updated"
fi

# ── 5. Database migrations ─────────────────────────────────────────────────────
if [[ "$SKIP_MIGRATE" == "false" && "$DRY_RUN" == "false" ]]; then
  step "Running database migrations"
  MIGRATE_IMAGE="${IMAGE:-ghcr.io/ayamigah16/poly-ochestrator-challenge:latest}"

  # Delete any previous migration job
  kubectl delete job migrate-job -n "$NAMESPACE" --ignore-not-found --wait

  # Use a Job (not a raw Pod) so kubectl wait --for=condition=Complete works
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: migrate-job
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: ${MIGRATE_IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["python", "-m", "alembic", "upgrade", "head"]
          envFrom:
            - secretRef:
                name: poly-orchestrator-secrets
            - configMapRef:
                name: poly-orchestrator-config
EOF

  info "Waiting for migration job to complete..."
  kubectl wait job/migrate-job \
    --for=condition=Complete \
    --timeout=120s \
    -n "$NAMESPACE" \
    || {
      warn "Migration job did not complete — logs:"
      kubectl logs -l job-name=migrate-job -n "$NAMESPACE" || true
      die "Migrations failed — aborting deploy"
    }

  success "Migrations complete"
  kubectl logs -l job-name=migrate-job -n "$NAMESPACE"
  kubectl delete job migrate-job -n "$NAMESPACE" --ignore-not-found
fi

# ── 6. Watch rollout ──────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "false" ]]; then
  step "Watching rollout (timeout: $TIMEOUT)"
  if kubectl rollout status deployment/poly-orchestrator \
      -n "$NAMESPACE" \
      --timeout="$TIMEOUT"; then
    success "Rollout complete"
  else
    error "Rollout did not complete within $TIMEOUT"
    echo ""
    warn "Run the rollback script to revert:"
    echo "  ./scripts/k8s-rollback.sh"
    exit 1
  fi

  # ── 7. Pod status ──────────────────────────────────────────────────────────
  step "Pod status"
  kubectl get pods -n "$NAMESPACE" -l app=poly-orchestrator \
    --sort-by='.metadata.creationTimestamp'

  # ── 8. Smoke test ──────────────────────────────────────────────────────────
  step "Smoke test via kubectl port-forward"
  POD=$(kubectl get pod -n "$NAMESPACE" -l app=poly-orchestrator \
    -o jsonpath='{.items[0].metadata.name}')
  if [[ -n "$POD" ]]; then
    kubectl port-forward "pod/$POD" 18000:8000 -n "$NAMESPACE" &
    PF_PID=$!
    sleep 3
    HEALTH=$(curl -sf http://localhost:18000/health || echo '{"error":"no response"}')
    kill "$PF_PID" 2>/dev/null || true
    echo "$HEALTH" | python3 -m json.tool 2>/dev/null || echo "$HEALTH"
    echo "$HEALTH" | grep -q '"status":"ok"' \
      && success "Health check passed" \
      || warn "Health response did not contain status:ok — investigate"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Kubernetes deploy complete!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  Rollback:        ./scripts/k8s-rollback.sh"
echo "  Logs:            kubectl logs -f -l app=poly-orchestrator -n $NAMESPACE"
echo "  Port-forward:    kubectl port-forward svc/poly-orchestrator 8000:80 -n $NAMESPACE"
echo ""
