#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/report_path_policy.sh"

suite="${1:?suite required}"
out_dir="$(tf_resolve_report_dir_or_fail "$REPO_ROOT" "${2:?output directory required}" "ForgeSec output directory")"
manifest_path="${3:?job manifest required}"
timeout_seconds="${4:-240}"
image_ref="${5:-}"
namespace="${FORGESEC_NAMESPACE:-forgesec}"
cleanup_jobs="${FORGESEC_CLEANUP_JOBS:-false}"

mkdir -p "$out_dir"

case "$suite" in
  identity|surface) ;;
  *)
    echo "[FAIL] unsupported ForgeSec suite: $suite" >&2
    exit 2
    ;;
esac

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found in PATH" >&2
  exit 2
fi

effective_manifest="$manifest_path"
if [[ -n "$image_ref" || "$namespace" != "forgesec" ]]; then
  effective_manifest="$out_dir/job-manifest.yaml"
  python3 - "$manifest_path" "$effective_manifest" "$image_ref" "$namespace" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
target = Path(sys.argv[2])
image_ref = sys.argv[3]
namespace = sys.argv[4]

updated = source
if image_ref:
    updated, count = re.subn(r'^(\s*image:\s*).+$', rf'\1{image_ref}', updated, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit("failed to override ForgeSec image reference in manifest")
updated = re.sub(r'^(\s*namespace:\s*)forgesec\s*$', rf'\1{namespace}', updated, flags=re.MULTILINE)
target.write_text(updated, encoding="utf-8")
PY
fi

created_job_ref="$(kubectl create -o name -f "$effective_manifest" 2>/dev/null || true)"

cleanup_job() {
  if [[ -n "${job_name:-}" && "$cleanup_jobs" = "true" ]]; then
    kubectl delete job "$job_name" -n "$namespace" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup_job EXIT

job_name="${created_job_ref##*/}"

if [[ -z "$job_name" ]]; then
  echo "[FAIL] no ${suite} job found after manifest create" >&2
  exit 2
fi

wait_rc=124
pod_name=""
last_seen_pod_name=""
completed_pod_name=""
deadline=$((SECONDS + timeout_seconds))
phase_start_epoch="$(date +%s)"
attempt=0
max_attempts=$(( (timeout_seconds + 1) / 2 + 1 ))
liveness_log="$out_dir/liveness.log"

emit_liveness() {
  local phase="$1"
  local reason="$2"
  local object="job/${job_name}"
  [[ -n "${pod_name:-$last_seen_pod_name}" ]] && object+=" pod/${pod_name:-$last_seen_pod_name}"
  printf 'PHASE_%s=%s ATTEMPT=%s MAX_ATTEMPTS=%s CURRENT_OBJECT=%s CURRENT_WAIT_REASON=%s DURATION=%ss\n' \
    "$phase" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$attempt" "$max_attempts" "$object" "$reason" \
    "$(( $(date +%s) - phase_start_epoch ))" | tee -a "$liveness_log" >&2
}

printf 'PHASE_START=%s ATTEMPT=0 MAX_ATTEMPTS=%s CURRENT_OBJECT=job/%s CURRENT_WAIT_REASON=job_creation_complete\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$max_attempts" "$job_name" | tee -a "$liveness_log" >&2

capture_artifacts() {
  local capture_pod_name="${1:-}"

  if kubectl get job "$job_name" -n "$namespace" -o json > "$out_dir/job.json" 2>/dev/null; then
    :
  fi

  if [[ -n "$capture_pod_name" ]]; then
    kubectl get pod "$capture_pod_name" -n "$namespace" -o json > "$out_dir/pod.json" 2>/dev/null || true
    kubectl logs -n "$namespace" "$capture_pod_name" --tail=-1 > "$out_dir/job.log" 2>&1 || true
  else
    kubectl logs -n "$namespace" "job/${job_name}" --tail=-1 > "$out_dir/job.log" 2>&1 || true
  fi
}

extract_runtime_image_id() {
  local source_json="$1"

  jq -r '.status.containerStatuses[]? | select(.name=="forgesec") | .imageID // .image' "$source_json" 2>/dev/null | head -n1
}

normalize_digest() {
  local image_ref="$1"

  if [[ -z "$image_ref" ]]; then
    return
  fi

  if [[ "$image_ref" == *"@sha256:"* ]]; then
    printf '%s\n' "${image_ref##*@}"
    return
  fi

  if [[ "$image_ref" =~ sha256:[a-f0-9]{64}$ ]]; then
    printf '%s\n' "${BASH_REMATCH[0]}"
  fi
}

while (( SECONDS < deadline )); do
  attempt=$((attempt + 1))
  job_state="$({
    kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.status.succeeded}{"\t"}{.status.failed}'
  } 2>/dev/null || true)"
  job_succeeded="${job_state%%$'\t'*}"
  job_failed="${job_state#*$'\t'}"
  [[ "$job_succeeded" =~ ^[0-9]+$ ]] || job_succeeded=0
  [[ "$job_failed" =~ ^[0-9]+$ ]] || job_failed=0

  pod_state="$({
    kubectl get pods -n "$namespace" -l "job-name=${job_name}" -o jsonpath='{.items[0].metadata.name}{"\t"}{.items[0].status.phase}'
  } 2>/dev/null || true)"
  if [[ -n "$pod_state" ]]; then
    pod_name="${pod_state%%$'\t'*}"
    pod_phase="${pod_state#*$'\t'}"
    last_seen_pod_name="$pod_name"
  else
    pod_name=""
    pod_phase=""
  fi

  if (( job_succeeded > 0 )) || [[ "$pod_phase" = "Succeeded" ]]; then
    emit_liveness "END" "completion_detected"
    completed_pod_name="${pod_name:-$last_seen_pod_name}"
    capture_artifacts "$completed_pod_name"
    wait_rc=0
    break
  fi

  if (( job_failed > 0 )) || [[ "$pod_phase" = "Failed" ]]; then
    emit_liveness "END" "failure_detected"
    completed_pod_name="${pod_name:-$last_seen_pod_name}"
    capture_artifacts "$completed_pod_name"
    wait_rc=1
    break
  fi

  if [[ -z "$pod_name" ]]; then
    wait_reason="pod_not_observed"
  else
    wait_reason="pod_phase_${pod_phase:-unknown}"
  fi
  emit_liveness "WAIT" "$wait_reason"
  sleep 2
done

if [[ "$wait_rc" -eq 124 ]]; then
  emit_liveness "END" "deadline_exhausted"
  capture_artifacts "${pod_name:-$last_seen_pod_name}"
fi

if [[ -n "$image_ref" && "$image_ref" == *"@sha256:"* && -f "$out_dir/pod.json" ]]; then
  expected_digest="${image_ref##*@}"
  runtime_image_id="$(extract_runtime_image_id "$out_dir/pod.json")"
  runtime_digest="$(normalize_digest "$runtime_image_id")"
  if [[ -z "$runtime_digest" && -n "${pod_name:-$last_seen_pod_name}" ]]; then
    live_pod_name="${pod_name:-$last_seen_pod_name}"
    live_pod_json="$out_dir/pod-live.json"
    if kubectl get pod "$live_pod_name" -n "$namespace" -o json > "$live_pod_json" 2>/dev/null; then
      runtime_image_id="$(extract_runtime_image_id "$live_pod_json")"
      runtime_digest="$(normalize_digest "$runtime_image_id")"
    fi
  fi
  if [[ -z "$runtime_digest" ]]; then
    echo "[FAIL] FORGESEC_RUNTIME_DIGEST_UNAVAILABLE: pod imageID missing digest" >&2
    exit 2
  fi
  if [[ "$runtime_digest" != "$expected_digest" ]]; then
    echo "[FAIL] FORGESEC_RUNTIME_MANIFEST_DIGEST_MISMATCH" >&2
    echo "[FAIL] expected=$image_ref" >&2
    echo "[FAIL] runtime=$runtime_image_id" >&2
    exit 2
  fi
fi

python3 - "$out_dir/job.log" "$out_dir/report.json" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
report_path = Path(sys.argv[2])
text = log_path.read_text(encoding="utf-8") if log_path.exists() else ""
match = re.search(r"FORGESEC_JSON_BEGIN\n(.*?)\nFORGESEC_JSON_END", text, re.S)
if match:
    report = json.loads(match.group(1))
else:
    report = {
        "suite": report_path.parent.name,
        "outcome": "missing-json",
        "results": [],
    }
report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
PY

failed_count="$({
  kubectl get job "$job_name" -n "$namespace" -o jsonpath='{.status.failed}'
} 2>/dev/null || true)"
outcome="$(python3 - "$out_dir/report.json" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(report.get("outcome", "missing-json"))
PY
)"

if [[ -n "$failed_count" && "$failed_count" != "0" ]]; then
  exit 1
fi

if [[ "$wait_rc" -ne 0 && "$outcome" == "missing-json" ]]; then
  echo "[FAIL] ForgeSec ${suite} job timed out before producing a verdict" >&2
  exit 2
fi

case "$outcome" in
  pass)
    exit 0
    ;;
  fail)
    exit 1
    ;;
  infra_fail)
    exit 2
    ;;
  *)
    echo "[FAIL] ForgeSec ${suite} job did not emit a usable result" >&2
    exit 2
    ;;
esac
