#!/usr/bin/env bash
# Roll back the Kubernetes deployment to the previous (or a specific) revision.
# Safe to run during an active incident — takes effect in seconds.
#
# Usage:
#   ./scripts/k8s-rollback.sh                        # roll back to previous revision
#   ./scripts/k8s-rollback.sh --revision 3           # roll back to a specific revision
#   ./scripts/k8s-rollback.sh --list                 # list available revisions
#   ./scripts/k8s-rollback.sh --namespace my-ns      # target a different namespace

source "$(dirname "$0")/lib.sh"

NAMESPACE="poly-orchestrator"
REVISION=""
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --revision)  REVISION="$2";    shift 2 ;;
    --namespace) NAMESPACE="$2";   shift 2 ;;
    --list)      LIST_ONLY=true;   shift   ;;
    --help|-h)
      grep '^#' "$0" | head -10 | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require kubectl

# ── List revisions ────────────────────────────────────────────────────────────
step "Rollout history"
kubectl rollout history deployment/poly-orchestrator -n "$NAMESPACE"

[[ "$LIST_ONLY" == "true" ]] && exit 0

# ── Current state ──────────────────────────────────────────────────────────────
echo ""
info "Current pods:"
kubectl get pods -n "$NAMESPACE" -l app=poly-orchestrator \
  --sort-by='.metadata.creationTimestamp'

# ── Confirm ────────────────────────────────────────────────────────────────────
echo ""
if [[ -n "$REVISION" ]]; then
  confirm "Roll back to revision $REVISION in namespace '$NAMESPACE'?"
  REVISION_FLAG="--to-revision=$REVISION"
else
  confirm "Roll back to the PREVIOUS revision in namespace '$NAMESPACE'?"
  REVISION_FLAG=""
fi

# ── Execute rollback ───────────────────────────────────────────────────────────
step "Executing rollback"
# shellcheck disable=SC2086
kubectl rollout undo deployment/poly-orchestrator \
  -n "$NAMESPACE" \
  $REVISION_FLAG

# ── Watch ──────────────────────────────────────────────────────────────────────
step "Watching rollback (timeout: 120s)"
kubectl rollout status deployment/poly-orchestrator \
  -n "$NAMESPACE" \
  --timeout=120s \
  && success "Rollback complete" \
  || die "Rollback did not stabilise in 120s — check pod events: kubectl describe pod -n $NAMESPACE -l app=poly-orchestrator"

# ── Verify ────────────────────────────────────────────────────────────────────
step "Post-rollback pod state"
kubectl get pods -n "$NAMESPACE" -l app=poly-orchestrator \
  --sort-by='.metadata.creationTimestamp'

echo ""
info "Current active revision:"
kubectl rollout history deployment/poly-orchestrator -n "$NAMESPACE" | tail -2

echo ""
echo -e "${GREEN}${BOLD}  Rollback successful.${RESET}"
echo "  Monitor: kubectl logs -f -l app=poly-orchestrator -n $NAMESPACE"
