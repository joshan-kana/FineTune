#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_clean_worktree() {
  if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    die "working tree is dirty; refusing an invasive Git operation"
  fi
}

create_safety_branch() {
  require_clean_worktree
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  git -C "$REPO_ROOT" branch "backup/pre-au-integration-$stamp"
  info "created safety branch backup/pre-au-integration-$stamp"
}
