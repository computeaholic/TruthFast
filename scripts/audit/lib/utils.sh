#!/usr/bin/env bash
set -uo pipefail

infer_root() {
  if [[ -n "${REPO_ROOT:-}" ]]; then
    return
  fi
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
}

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

banner() {
  printf '\n== %s ==\n' "$1"
}

section() {
  printf '\n-- %s --\n' "$1"
}

ok() {
  printf '[OK] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_audit_dirs() {
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR/raw" "$OUT_DIR/meta" "$OUT_DIR/sbom" "$OUT_DIR/forgesec"
  : > "$OUT_DIR/meta/checks.tsv"
}

record_check() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$OUT_DIR/meta/checks.tsv"
}

write_phase_json() {
  local phase="$1"
  local title="$2"
  local status="$3"
  local evidence_json="$4"
  cat > "$OUT_DIR/raw/phase_${phase}.json" <<EOF
{
  "phase": "$phase",
  "title": "$title",
  "status": "$status",
  "ts": "$(timestamp_utc)",
  "evidence": $evidence_json
}
EOF
}

run_phase() {
  local phase="$1"
  local title="$2"
  local func="$3"
  local log_path="$OUT_DIR/raw/${phase}.log"
  local summary="completed"
  local rc=0

  echo "[PHASE START] $phase"
  section "$title"
  AUDIT_PHASE_STATUS=""
  if "$func" >"$log_path" 2>&1; then
    if [[ -z "$AUDIT_PHASE_STATUS" ]]; then
      AUDIT_PHASE_STATUS="PASS"
    fi
  else
    rc=$?
    summary="returned rc=${rc}"
    AUDIT_PHASE_STATUS="FAIL"
  fi

  case "$AUDIT_PHASE_STATUS" in
    PASS) ok "$title" ;;
    WARN) warn "$title ($summary)" ;;
    FAIL) warn "$title ($summary)" ;;
    *)
      AUDIT_PHASE_STATUS="WARN"
      warn "$title (status=${AUDIT_PHASE_STATUS})"
      ;;
  esac

  record_check "$phase" "$title" "$AUDIT_PHASE_STATUS" "$summary"
  echo "[PHASE END] $phase status=$AUDIT_PHASE_STATUS"
  return 0
}

json_bool() {
  if [[ "$1" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}
