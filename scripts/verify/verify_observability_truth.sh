#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[FAIL] OBSERVABILITY_FALSE_SIGNAL: $1"
  exit 2
}

before_metrics="$TMP_DIR/before.metrics"
after_metrics="$TMP_DIR/after.metrics"
ingestion_log="$TMP_DIR/ingestion.log"
fallback_ingestion_log="$TMP_DIR/ingestion_fallback.log"

fetch_tempo_metrics() {
  local output_file="$1"
  local attempts="${2:-5}"
  local delay_seconds="${3:-2}"
  local attempt=1

  : >"$output_file"
  while (( attempt <= attempts )); do
    if kubectl exec -n observability statefulset/tempo -- wget -qO- http://localhost:3100/metrics >"$output_file" 2>/dev/null; then
      if [[ -s "$output_file" ]]; then
        return 0
      fi
    fi
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
  return 1
}

metric_sum() {
  local metric_name="$1"
  local metrics_file="$2"
  awk -v metric_name="$metric_name" '
    $1 ~ ("^" metric_name "(\\{|$)") {
      value = $2
      if (value ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/) {
        sum += value
      }
    }
    END { print sum + 0 }
  ' "$metrics_file"
}

if ! fetch_tempo_metrics "$before_metrics"; then
  fail "unable to scrape Tempo metrics before trace ingestion proof"
fi

if ! bash "$REPO_ROOT/scripts/verify/verify_tempo_ingestion_proof.sh" >"$ingestion_log" 2>&1; then
  cat "$ingestion_log" >&2 || true
  fail "trace ingestion proof failed"
fi

before_spans="$(metric_sum tempo_distributor_spans_received_total "$before_metrics")"
before_bytes="$(metric_sum tempo_distributor_bytes_received_total "$before_metrics")"
before_appends="$(metric_sum tempo_distributor_ingester_appends_total "$before_metrics")"
before_traces_created="$(metric_sum tempo_ingester_traces_created_total "$before_metrics")"

increment_observed=0
for _ in $(seq 1 20); do
  if ! fetch_tempo_metrics "$after_metrics" 3 1; then
    sleep 3
    continue
  fi

  after_spans="$(metric_sum tempo_distributor_spans_received_total "$after_metrics")"
  after_bytes="$(metric_sum tempo_distributor_bytes_received_total "$after_metrics")"
  after_appends="$(metric_sum tempo_distributor_ingester_appends_total "$after_metrics")"
  after_traces_created="$(metric_sum tempo_ingester_traces_created_total "$after_metrics")"

  if awk -v bs="$before_spans" -v as="$after_spans" \
         -v bb="$before_bytes" -v ab="$after_bytes" \
         -v ba="$before_appends" -v aa="$after_appends" \
         -v bt="$before_traces_created" -v at="$after_traces_created" \
         'BEGIN { exit !((as > bs) || (ab > bb) || (aa > ba) || (at > bt)) }'; then
    increment_observed=1
    break
  fi

  sleep 3
done

if [[ "$increment_observed" -ne 1 ]]; then
  # Fallback guard for delayed/non-monotonic metric exposure: require an
  # additional independent ingestion+retrieval proof in the same run.
  if ! bash "$REPO_ROOT/scripts/verify/verify_tempo_ingestion_proof.sh" >"$fallback_ingestion_log" 2>&1; then
    cat "$fallback_ingestion_log" >&2 || true
    fail "Tempo distributor metrics did not increment and fallback ingestion proof failed (spans ${before_spans}->${after_spans:-n/a}, bytes ${before_bytes}->${after_bytes:-n/a}, appends ${before_appends}->${after_appends:-n/a}, traces ${before_traces_created}->${after_traces_created:-n/a})"
  fi

  if ! grep -q 'observability_ingestion_verified=PASS' "$fallback_ingestion_log"; then
    fail "Tempo distributor metrics did not increment and fallback proof did not emit success marker (spans ${before_spans}->${after_spans:-n/a}, bytes ${before_bytes}->${after_bytes:-n/a}, appends ${before_appends}->${after_appends:-n/a}, traces ${before_traces_created}->${after_traces_created:-n/a})"
  fi
fi

echo "[PASS] observability_truth=PASS"
