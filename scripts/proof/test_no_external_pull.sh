#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PIN_MAP_PATH="${PIN_MAP_PATH:-$REPO_ROOT/platform/config/image_pin_map.json}"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

# Fail if any running workload image or recent image pull event references an external registry host.

NAMESPACE_RE='^(threadforge($|-)|threadforge-test$|threadforge-lab$|observability$|istio-system$|spire-system$|argocd$|minio$|tempo$|loki$|cert-manager$|kyverno$|forgesec$)'

ensure_cluster_readable || exit $?

if [ ! -f "$PIN_MAP_PATH" ]; then
  echo "[FAIL] image pin map missing: $PIN_MAP_PATH"
  exit 10
fi

declare -A APPROVED_TAG_ALIASES=()
while IFS= read -r alias_ref; do
  [ -n "$alias_ref" ] || continue
  APPROVED_TAG_ALIASES["$alias_ref"]=1
done < <(python3 - <<'PY' "$PIN_MAP_PATH"
import json
import pathlib
import sys

pin_map = json.loads(pathlib.Path(sys.argv[1]).read_text())
for key in pin_map.keys():
    print(key)
PY
)

tmp_images="$(mktemp)"
tmp_events="$(mktemp)"
proof_start_epoch="$(date +%s)"
cleanup() {
  rm -f "$tmp_images" "$tmp_events"
}
trap cleanup EXIT

tmp_ns="$(mktemp)"
trap 'cleanup; rm -f "$tmp_ns"' EXIT

kubectl get ns --no-headers 2>/dev/null | awk '{print $1}' | grep -E "$NAMESPACE_RE" > "$tmp_ns" || true

while IFS= read -r ns; do
  [ -n "$ns" ] || continue
  kubectl get pods -n "$ns" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null || true
done < "$tmp_ns" | sed '/^$/d' | sort -u > "$tmp_images"

if [ ! -s "$tmp_images" ]; then
  echo "[FAIL] no running pod images found"
  exit 2
fi

# Every running image must be internal and digest-pinned.
violations=0
while IFS= read -r image; do
  registry="${image%%/*}"

  if [ "$registry" != "registry.threadforge.local:30500" ]; then
    echo "[FAIL] non-internal registry host: $image"
    violations=$((violations + 1))
    continue
  fi

  if [[ ! "$image" =~ @sha256:[a-f0-9]{64}$ ]] && [[ -z "${APPROVED_TAG_ALIASES[$image]:-}" ]]; then
    echo "[FAIL] image is not digest-pinned: $image"
    violations=$((violations + 1))
    continue
  fi
done < "$tmp_images"

# Check recent kube events for external pull attempts.
while IFS= read -r ns; do
  [ -n "$ns" ] || continue
  kubectl get events -n "$ns" -o json 2>/dev/null || true
done < "$tmp_ns" | jq -r --argjson start "$proof_start_epoch" '
  .items[]? as $e
  | ($e.lastTimestamp // $e.eventTime // "") as $ts
  | ($e.message // "") as $msg
  | ($e.reason // "") as $reason
  | if ($reason != "Pulling") then empty
    else
      (($ts | sub("\\..*Z$";"Z") | fromdateiso8601?) // 0) as $evt
      | if $evt >= ($start - 120) then
          "\($e.involvedObject.namespace // "")\t\($e.involvedObject.name // "")\t\($ts)\t\($msg)"
        else empty end
    end
' > "$tmp_events"

external_pull_events="$(awk '
  match($0, /Pulling image "[^"]+"/) {
    if ($0 ~ /(external-test|unsigned-test|unsigned-internal-test|signed-test|task-f-sidecar-test|test-injection)/) {
      next
    }
    image = substr($0, RSTART + 15, RLENGTH - 16)
    registry = image
    sub(/\/.*/, "", registry)
    if (registry != "registry.threadforge.local:30500") {
      print NR ":" $0
    }
  }
' "$tmp_events")"

if [ -n "$external_pull_events" ]; then
  echo "[FAIL] external pull attempt detected in cluster events"
  printf '%s\n' "$external_pull_events" | head -20
  violations=$((violations + 1))
fi

if [ "$violations" -gt 0 ]; then
  echo "[FAIL] external pull policy violations: $violations"
  exit 2
fi

echo "[PASS] no external pull hosts detected in running images or recent pull events"
exit 0
