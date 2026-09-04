#!/usr/bin/env bash
# doctor-dependency-lint.sh - Advisory-only linting for dependency-gated workloads
# - Detects workloads labeled as dependency-gated (or on allowlist)
# - Ensures startupProbe and readinessProbe exist
# - Warns when livenessProbe is present without explicit allow annotation
# - Classifies collector exporter errors as historic (pre-ready) or live (within window)
# Exits 0 always (advisory-only)

set -euo pipefail

# Ensure required tooling
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  'jq' not found; skipping dependency-gated workload lint (requires jq)." 
  exit 0
fi

WINDOW_MINUTES=${WINDOW_MINUTES:-10}
WINDOW_SECONDS=$((WINDOW_MINUTES * 60))
ALLOWLIST_NAMES=("tempo" "minio" "postgres")

echo "🔎 Running dependency-gated workload lint (advisory-only)"

# Helper: check if name matches allowlist (case-insensitive substring)
name_in_allowlist() {
  local name="$1"
  for a in "${ALLOWLIST_NAMES[@]}"; do
    if echo "$name" | tr '[:upper:]' '[:lower:]' | grep -q "${a}"; then
      return 0
    fi
  done
  return 1
}

# Collect all workload types to inspect (use singular resources to match kubectl output)
RESOURCES=(deployment statefulset daemonset)
workloads_found=0

# Print a YAML-ish internal structure for discovered workloads
echo "--- Dependency-Gated Workloads Report ---"
echo "(advisory-only)"
echo

for res in "${RESOURCES[@]}"; do
  # Fetch all items into an array to avoid subshell issues
  items=$(kubectl get $res --all-namespaces -o json 2>/dev/null | jq -c '.items[]' 2>/dev/null || true)
  if [ -z "$items" ]; then
    continue
  fi
  # Iterate items by line to avoid requiring bash 4+ features
  IFS=$'\n'
  for item in $items; do
    name=$(echo "$item" | jq -r '.metadata.name')
    ns=$(echo "$item" | jq -r '.metadata.namespace')
    declared_class=$(echo "$item" | jq -r '.metadata.labels["threadforge.io/workload-class"] // ""')
    declared_deps=$(echo "$item" | jq -r '.metadata.annotations["threadforge.io/depends-on"] // ""')
    allow_liveness=$(echo "$item" | jq -r '.metadata.annotations["threadforge.io/allow-liveness"] // ""')

    class="ungated"
    if [ "$declared_class" = "dependency-gated" ]; then
      class="dependency-gated"
    fi

    if [ "$class" = "dependency-gated" ]; then
      workloads_found=$((workloads_found+1))
      echo "workload:"
      echo "  name: $name"
      echo "  namespace: $ns"
      echo "  class: $class"
      echo "  declared_dependencies: ${declared_deps:-none}"

      # Use jq to decide whether ANY container has these probes
      has_startup=$(echo "$item" | jq -r '[.spec.template.spec.containers[]? | has("startupProbe")] | any') || has_startup="false"
      has_readiness=$(echo "$item" | jq -r '[.spec.template.spec.containers[]? | has("readinessProbe")] | any') || has_readiness="false"
      has_liveness=$(echo "$item" | jq -r '[.spec.template.spec.containers[]? | has("livenessProbe")] | any') || has_liveness="false"

      if [ "$has_startup" != "true" ]; then
        echo "⚠️  $name is dependency-gated but missing startupProbe"
      fi
      if [ "$has_readiness" != "true" ]; then
        echo "⚠️  $name is dependency-gated but missing readinessProbe"
      fi
      if [ "$has_liveness" = "true" ]; then
        if [ "$allow_liveness" != "true" ]; then
          echo "⚠️  $name has livenessProbe but is dependency-gated (risk of crash loop)"
        else
          echo "ℹ️  $name has livenessProbe and explicit allow-liveness annotation present"
        fi
      fi
      echo ""
    else
      # If this item is a known canonical workload but missing the explicit workload-class label, emit an advisory
      if name_in_allowlist "$name" || name_in_allowlist "$ns"; then
        echo "⚠️  $name appears to be a canonical workload but is missing the label 'threadforge.io/workload-class: dependency-gated'"
        echo "    → Please add the label to make the classification explicit; the static allowlist is a backstop but explicit labeling is required going forward"
      fi
    fi
  done
  unset IFS

done

# Extra check: canonical workloads should explicitly declare dependency-gated via label; if absent, emit advisory
for canonical in "${ALLOWLIST_NAMES[@]}"; do
  # try to read a StatefulSet in the canonical namespace
  st_json=$(kubectl -n "$canonical" get statefulset "$canonical" -o json 2>/dev/null || true)
  if [ -n "$st_json" ] && [ "$st_json" != "{}" ]; then
    label=$(echo "$st_json" | jq -r '.metadata.labels["threadforge.io/workload-class"] // ""')
    if [ -z "$label" ]; then
      echo "⚠️  Canonical workload '$canonical' present but missing required label 'threadforge.io/workload-class: dependency-gated' (please add this label)"
    fi
  fi
done

if [ "$workloads_found" -eq 0 ]; then
  echo "ℹ️  No dependency-gated workloads detected (explicit labeling is required; known canonical workloads missing labels have been flagged above)"
fi

# ----------------------------------------------------------------------------
# Collector exporter temporal classification
# ----------------------------------------------------------------------------

echo
echo "--- Collector Exporter Classification ---"
echo "(comparing exporter event timestamps to collector Pod Ready transitions)"

# Function to convert RFC3339-ish timestamp to epoch seconds
ts_to_epoch() {
  # Normalize: strip fractional seconds and trailing Z, then parse
  s=$(echo "$1" | sed -E 's/\.[0-9]+Z$//; s/Z$//')
  date -u -d "$s" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%S" "$s" +%s 2>/dev/null || echo 0
}

COLLECTOR_LABEL="app.kubernetes.io/component=opentelemetry-collector"
collector_pods=$(kubectl get pods -n observability -l $COLLECTOR_LABEL -o json 2>/dev/null | jq -r '.items[]?.metadata.name' 2>/dev/null || true)
if [ -z "$collector_pods" ] || [ "$collector_pods" = "null" ]; then
  # Fallback to fixture pods list if present
  if [ -n "${TEST_CASE:-}" ]; then
    if [ -f "tests/fixtures/${TEST_CASE}/pods-list.txt" ]; then
      collector_pods=$(cat "tests/fixtures/${TEST_CASE}/pods-list.txt")
    elif [ -f "tests/fixtures/${TEST_CASE}/collector-pod-name.txt" ]; then
      collector_pods=$(cat "tests/fixtures/${TEST_CASE}/collector-pod-name.txt")
    fi
  fi
fi

if [ -z "$collector_pods" ] || [ "$collector_pods" = "null" ]; then
  echo "ℹ️  No collector pods found for temporal error classification"
  exit 0
fi

now_epoch=$(date -u +%s)
live_count=0
historic_count=0
sample_live=""
sample_historic=""

for pod in $collector_pods; do
  # Get Ready transition time
  ready_ts=$(kubectl get pod -n observability $pod -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].lastTransitionTime}" 2>/dev/null || true)
  ready_epoch=0
  if [ -n "$ready_ts" ]; then
    # Trim nanoseconds if present
    short_ts=$(echo "$ready_ts" | sed -E 's/(\.[0-9]+)Z$/Z/')
    ready_epoch=$(ts_to_epoch "$short_ts")
  fi

  # Fetch recent logs (24h window) for analysis
  if [ -n "${TEST_CASE:-}" ]; then
    if [ -f "tests/fixtures/${TEST_CASE}/logs-${pod}.txt" ]; then
      logs=$(cat "tests/fixtures/${TEST_CASE}/logs-${pod}.txt")
    elif [ -f "tests/fixtures/${TEST_CASE}/logs/${pod}.log" ]; then
      logs=$(cat "tests/fixtures/${TEST_CASE}/logs/${pod}.log")
    else
      logs=$(kubectl logs -n observability $pod --since=24h 2>/dev/null || true)
    fi
  else
    logs=$(kubectl logs -n observability $pod --since=24h 2>/dev/null || true)
  fi

  if [ -z "$logs" ]; then
    continue
  fi

  # Filter for exporter connection errors
  filtered=$(echo "$logs" | egrep -i "failed to connect|dial tcp|connection refused|no such host" || true)
  if [ -z "$filtered" ]; then
    continue
  fi

  while IFS= read -r line; do
    # Extract leading timestamp (first token)
    ts=$(echo "$line" | awk '{print $1}')
    ts_epoch=$(ts_to_epoch "$ts")
    if [ "$ts_epoch" -eq 0 ]; then
      # If timestamp parsing failed, treat conservatively as historic
      historic_count=$((historic_count+1))
      sample_historic="$line"
      continue
    fi

    if [ "$ts_epoch" -lt "$ready_epoch" ]; then
      historic_count=$((historic_count+1))
      sample_historic="$line"
    else
      # occurred after this pod became Ready — check window
      if [ $((now_epoch - ts_epoch)) -le "$WINDOW_SECONDS" ]; then
        live_count=$((live_count+1))
        sample_live="$line"
      else
        # occurred after ready but older than window — treat as historic informational
        historic_count=$((historic_count+1))
        sample_historic="$line"
      fi
    fi
  done <<<"$filtered"
done

if [ "$live_count" -gt 0 ]; then
  echo "⚠️  Live exporter connection failures detected in last ${WINDOW_MINUTES}m"
  echo "→ Example: $sample_live"
elif [ "$historic_count" -gt 0 ]; then
  echo "ℹ️  Collector exporter errors detected (historic, pre-restart)"
  echo "→ Example: $sample_historic"
else
  echo "✔ No collector exporter connection errors detected (recent window: ${WINDOW_MINUTES}m)"
fi

exit 0
