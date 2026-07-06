#!/usr/bin/env bash
# Cut a versioned release: validate, tag, push — triggering the CI release pipeline.
# Must be run from the main branch with a clean working tree and green CI.
#
# Usage:
#   ./scripts/release.sh 0.2.0
#   ./scripts/release.sh 0.2.0 --message "add competitor trend chart"
#   ./scripts/release.sh 0.2.0 --dry-run   # validate only, no tag or push

source "$(dirname "$0")/lib.sh"

VERSION="${1:-}"
MESSAGE=""
DRY_RUN=false

shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --message|-m) MESSAGE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift   ;;
    --help|-h)
      grep '^#' "$0" | head -8 | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require git python3

# ── Validate version ───────────────────────────────────────────────────────────
[[ -z "$VERSION" ]] && die "Usage: $0 <semver>  e.g.  $0 0.2.0"

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  die "Version must be semver (MAJOR.MINOR.PATCH) — got: $VERSION"
fi

TAG="v$VERSION"
[[ -z "$MESSAGE" ]] && MESSAGE="Release $TAG"

cd "$REPO_ROOT"

# ── Branch check ───────────────────────────────────────────────────────────────
step "Branch check"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  die "Releases must be cut from 'main'. Current branch: $CURRENT_BRANCH"
fi
success "On branch: main"

# ── Clean working tree ─────────────────────────────────────────────────────────
step "Working tree check"
if ! git diff --quiet || ! git diff --cached --quiet; then
  git status --short
  die "Working tree has uncommitted changes — commit or stash them first"
fi
success "Working tree is clean"

# ── Sync with origin ───────────────────────────────────────────────────────────
step "Syncing with origin/main"
git fetch origin main --tags --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [[ "$LOCAL" != "$REMOTE" ]]; then
  die "Local main is not in sync with origin/main — run: git pull origin main"
fi
success "In sync with origin/main"

# ── Tag collision check ────────────────────────────────────────────────────────
step "Tag check"
if git tag | grep -q "^${TAG}$"; then
  die "Tag $TAG already exists — choose a different version"
fi
success "Tag $TAG is available"

# ── Tests pass? ───────────────────────────────────────────────────────────────
if command -v pytest &>/dev/null; then
  step "Running tests before tagging"
  pytest --no-cov -q \
    && success "Tests passed" \
    || die "Tests failed — fix them before releasing"
else
  warn "pytest not found in PATH — skipping local test run (rely on CI)"
fi

# ── Changelog preview ─────────────────────────────────────────────────────────
step "Commits since last release"
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -n "$PREV_TAG" ]]; then
  info "Changes since $PREV_TAG:"
  git log "${PREV_TAG}..HEAD" --oneline
else
  info "No previous tags — showing last 10 commits:"
  git log -10 --oneline
fi

# ── Dry run exit ──────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  info "Dry run complete — no tag created."
  info "Would create: $TAG  \"$MESSAGE\""
  exit 0
fi

# ── Confirm ────────────────────────────────────────────────────────────────────
echo ""
info "About to create and push tag: ${BOLD}$TAG${RESET}"
info "Message: $MESSAGE"
confirm "Proceed with release $TAG?"

# ── Tag and push ───────────────────────────────────────────────────────────────
step "Creating annotated tag $TAG"
git tag -a "$TAG" -m "$MESSAGE"
success "Tag created locally"

step "Pushing tag to origin (triggers CI release pipeline)"
git push origin "$TAG"
success "Tag pushed"

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Release $TAG triggered!${RESET}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  CI will now:"
echo "    1. Build the Docker image"
echo "    2. Push  ghcr.io/ayamigah16/poly-ochestrator-challenge:$TAG"
echo "    3. Push  ghcr.io/ayamigah16/poly-ochestrator-challenge:latest"
echo "    4. Create a GitHub Release with changelog + digest"
echo ""
echo "  Monitor progress:"
echo "    gh run list --workflow release.yml"
echo ""
echo "  Deploy to production once the image is published:"
echo "    ./scripts/k8s-deploy.sh --image ghcr.io/ayamigah16/poly-ochestrator-challenge:$TAG"
