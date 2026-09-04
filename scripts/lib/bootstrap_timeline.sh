#!/usr/bin/env bash

# shellcheck shell=bash

if [[ -n "${THREADFORGE_BOOTSTRAP_TIMELINE_SOURCED:-}" ]]; then
  return 0
fi
THREADFORGE_BOOTSTRAP_TIMELINE_SOURCED=1

declare -g THREADFORGE_BOOTSTRAP_TIMELINE_ROOT=""
declare -g THREADFORGE_BOOTSTRAP_TIMELINE_EVENTS=""

declare -gA TF_BT_PHASE_START_EPOCH=()
declare -gA TF_BT_PHASE_START_TS=()
declare -gA TF_BT_PHASE_RETRY_COUNT=()
declare -gA TF_BT_PHASE_FIRST_FAILURE=()
declare -gA TF_BT_PHASE_LAST_MARKER=()

tf_bt_iso_utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

tf_bt_init() {
  local repo_root="${1:-}"
  [[ -n "$repo_root" ]] || return 0
  THREADFORGE_BOOTSTRAP_TIMELINE_ROOT="$repo_root"
  mkdir -p "$repo_root/artifacts"
  THREADFORGE_BOOTSTRAP_TIMELINE_EVENTS="$repo_root/artifacts/bootstrap_timeline.events.jsonl"
  if [[ "${TF_BT_RESET_EVENTS:-0}" == "1" || ! -f "$THREADFORGE_BOOTSTRAP_TIMELINE_EVENTS" ]]; then
    : > "$THREADFORGE_BOOTSTRAP_TIMELINE_EVENTS"
  fi
}

tf_bt_append_event() {
  local phase="$1"
  local status="$2"
  local start_ts="$3"
  local end_ts="$4"
  local duration_seconds="$5"
  local retry_count="$6"
  local first_failure_line="$7"
  local last_progress_marker="$8"

  [[ -n "${THREADFORGE_BOOTSTRAP_TIMELINE_EVENTS:-}" ]] || return 0

  python3 - "$THREADFORGE_BOOTSTRAP_TIMELINE_EVENTS" "$phase" "$status" "$start_ts" "$end_ts" "$duration_seconds" "$retry_count" "$first_failure_line" "$last_progress_marker" <<'PY'
import json
import sys

(
    events_file,
    phase,
    status,
    start_ts,
    end_ts,
    duration_seconds,
    retry_count,
    first_failure_line,
    last_progress_marker,
) = sys.argv[1:]

event = {
    "phase": phase,
    "status": status,
    "start_timestamp": start_ts,
    "end_timestamp": end_ts,
    "duration_seconds": int(duration_seconds),
    "retry_count": int(retry_count),
    "first_failure_line": first_failure_line,
    "last_progress_marker": last_progress_marker,
}

with open(events_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(event, ensure_ascii=True) + "\n")
PY
}

tf_bt_phase_start() {
  local phase="$1"
  local marker="${2:-start}"
  TF_BT_PHASE_START_EPOCH["$phase"]="$(date +%s)"
  TF_BT_PHASE_START_TS["$phase"]="$(tf_bt_iso_utc_now)"
  TF_BT_PHASE_RETRY_COUNT["$phase"]="${TF_BT_PHASE_RETRY_COUNT[$phase]:-0}"
  TF_BT_PHASE_FIRST_FAILURE["$phase"]="${TF_BT_PHASE_FIRST_FAILURE[$phase]:-}"
  TF_BT_PHASE_LAST_MARKER["$phase"]="$marker"
}

tf_bt_phase_progress() {
  local phase="$1"
  local marker="$2"
  TF_BT_PHASE_LAST_MARKER["$phase"]="$marker"
}

tf_bt_phase_retry() {
  local phase="$1"
  local reason="$2"
  local retries="${TF_BT_PHASE_RETRY_COUNT[$phase]:-0}"
  retries=$((retries + 1))
  TF_BT_PHASE_RETRY_COUNT["$phase"]="$retries"
  TF_BT_PHASE_LAST_MARKER["$phase"]="retry#${retries}: ${reason}"
}

tf_bt_phase_failure() {
  local phase="$1"
  local failure_line="$2"
  if [[ -z "${TF_BT_PHASE_FIRST_FAILURE[$phase]:-}" ]]; then
    TF_BT_PHASE_FIRST_FAILURE["$phase"]="$failure_line"
  fi
  TF_BT_PHASE_LAST_MARKER["$phase"]="$failure_line"
}

tf_bt_phase_end() {
  local phase="$1"
  local status="$2"
  local end_marker="${3:-end}"
  local end_epoch end_ts start_epoch start_ts duration retries first_failure last_marker

  end_epoch="$(date +%s)"
  end_ts="$(tf_bt_iso_utc_now)"
  start_epoch="${TF_BT_PHASE_START_EPOCH[$phase]:-$end_epoch}"
  start_ts="${TF_BT_PHASE_START_TS[$phase]:-$end_ts}"
  duration=$((end_epoch - start_epoch))
  retries="${TF_BT_PHASE_RETRY_COUNT[$phase]:-0}"
  first_failure="${TF_BT_PHASE_FIRST_FAILURE[$phase]:-}"
  last_marker="${TF_BT_PHASE_LAST_MARKER[$phase]:-$end_marker}"

  tf_bt_append_event "$phase" "$status" "$start_ts" "$end_ts" "$duration" "$retries" "$first_failure" "$last_marker"
}
