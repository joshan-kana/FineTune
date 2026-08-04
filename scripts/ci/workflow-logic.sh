#!/usr/bin/env bash

upstream_delta_count() {
  git rev-list --count "$1..$2"
}

workflow_command_available() {
  command -v "$1" >/dev/null 2>&1
}

workflow_should_update_pr() {
  [[ "$1" -gt 0 ]]
}

workflow_merge_guard() {
  local expected_head="$1"
  local actual_head="$2"
  local check_result="$3"
  [[ "$expected_head" == "$actual_head" && "$check_result" == "success" ]]
}

workflow_should_close_conflict_issue() {
  local merged="$1"
  local merged_at="$2"
  local expected_head="$3"
  local actual_head="$4"
  local expected_pr="$5"
  local actual_pr="$6"
  [[ "$merged" == "true" &&
    -n "$merged_at" &&
    "$merged_at" != "null" &&
    "$expected_head" == "$actual_head" &&
    "$expected_pr" == "$actual_pr" ]]
}
