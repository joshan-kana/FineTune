#!/usr/bin/env bash
set -euo pipefail

if [[ -n ${FINETUNE_REPO_ROOT:-} ]]; then
  REPO_ROOT="$FINETUNE_REPO_ROOT"
elif REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

BUILD_ROOT="$REPO_ROOT/.build"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
RESULTS_ROOT="$BUILD_ROOT/Results"
PRODUCTS_ROOT="$BUILD_ROOT/Products"
LOG_ROOT="$BUILD_ROOT/Logs"

info() { printf '%s\n' "[FineTune] $*"; }
warn() { printf '%s\n' "[FineTune] warning: $*" >&2; }
die() {
  printf '%s\n' "[FineTune] error: $*" >&2
  exit 1
}
has_command() { command -v "$1" >/dev/null 2>&1; }

ensure_repo() {
  [[ -d "$REPO_ROOT/FineTune.xcodeproj" ]] || die "FineTune.xcodeproj was not found under $REPO_ROOT"
}

mkdir_build_dirs() {
  mkdir -p "$DERIVED_DATA" "$RESULTS_ROOT" "$PRODUCTS_ROOT" "$LOG_ROOT"
}

project_file() { printf '%s\n' "$REPO_ROOT/FineTune.xcodeproj"; }
scheme_name() { printf '%s\n' "FineTune"; }

bundle_path() {
  printf '%s\n' "${1:-$PRODUCTS_ROOT/Debug/FineTune.app}"
}

require_macos() {
  [[ "$(uname -s)" == Darwin ]] || die "FineTune's Xcode application can only build on macOS"
}
