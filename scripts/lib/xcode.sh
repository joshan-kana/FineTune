#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

resolve_developer_dir() {
  local selected="${DEVELOPER_DIR:-}"
  if [[ -z $selected ]]; then
    selected="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  fi
  if [[ -z $selected ]]; then
    selected="/Applications/Xcode.app/Contents/Developer"
  fi
  printf '%s\n' "$selected"
}

require_full_xcode() {
  require_macos
  local selected
  selected="$(resolve_developer_dir)"
  [[ $selected != */CommandLineTools* ]] || die "full Xcode is required; select it with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
  [[ -x "$selected/usr/bin/xcodebuild" ]] || die "full Xcode was not found at $selected"
  export DEVELOPER_DIR="$selected"
  has_command xcodebuild || die "xcodebuild is unavailable from $DEVELOPER_DIR"
  has_command xcrun || die "xcrun is unavailable from $DEVELOPER_DIR"
  local sdk
  sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || die "macOS SDK is unavailable from $DEVELOPER_DIR"
  [[ -d $sdk ]] || die "macOS SDK path does not exist: $sdk"
  xcodebuild -license check >/dev/null 2>&1 || die "the Xcode license is not accepted; run sudo xcodebuild -license"
}

print_xcode_info() {
  require_full_xcode
  info "developer directory: $DEVELOPER_DIR"
  info "$(xcodebuild -version | head -1)"
  info "SDK: $(xcrun --sdk macosx --show-sdk-path)"
}

xcode_configuration() { printf '%s\n' "${FINETUNE_CONFIGURATION:-Debug}"; }
xcode_archs() { printf '%s\n' "${FINETUNE_ARCHS:-arm64}"; }
