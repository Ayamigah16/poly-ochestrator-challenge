#!/usr/bin/env bash
# Shared helpers sourced by every deployment script.
# Usage: source "$(dirname "$0")/lib.sh"

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Logging ────────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}▶ $*${RESET}"; }
die()     { error "$*"; exit 1; }

# ── Requirement checks ─────────────────────────────────────────────────────────
require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is not installed or not on PATH"
  done
}

# ── Confirmation prompt ────────────────────────────────────────────────────────
confirm() {
  local msg="${1:-Are you sure?}"
  read -r -p "$(echo -e "${YELLOW}${msg} [y/N] ${RESET}")" ans
  [[ "${ans,,}" == "y" ]] || { info "Aborted."; exit 0; }
}

# ── Wait for HTTP endpoint ─────────────────────────────────────────────────────
wait_for_http() {
  local url="$1" retries="${2:-30}" delay="${3:-3}"
  info "Waiting for $url ..."
  for ((i=1; i<=retries; i++)); do
    if curl -sf --max-time 5 "$url" &>/dev/null; then
      success "$url is reachable"
      return 0
    fi
    echo -n "."
    sleep "$delay"
  done
  echo ""
  die "Timed out waiting for $url after $((retries * delay))s"
}

# ── Repo root ─────────────────────────────────────────────────────────────────
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
