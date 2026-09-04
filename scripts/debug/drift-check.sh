#!/usr/bin/env bash
# Authority Domain: identity_gated
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

STRICT=${STRICT:-0}
TMPDIR=$(mktemp -d)

# List of "repo_file|kind|name|namespace" (namespace optional)
resources=(
  "platform/deploy/infra/tempo/templates/tempo-networkpolicy.yaml|NetworkPolicy|tempo-restrict|tempo"
  "platform/deploy/infra/istio/patches/istiod-gateway-clusterip.yaml|Service|istiod-gateway|istio-system"
)

normalize() {
  # Remove non-deterministic fields for comparison; silence sed stderr for portability
  sed -e '/^[[:space:]]*creationTimestamp:/d' \
      -e '/^[[:space:]]*resourceVersion:/d' \
      -e '/^[[:space:]]*uid:/d' \
      -e '/^[[:space:]]*generation:/d' \
      -e '/^[[:space:]]*managedFields:/,/-/d' \
      -e '/kubectl.kubernetes.io\/last-applied-configuration/d' \
      -e '/^[[:space:]]*annotations:/,/^[[:space:]]*[^[:space:]]/ { /kubectl.kubernetes.io\/last-applied-configuration/d }' 2>/dev/null || true
}

had_drift=0

for r in "${resources[@]}"; do
  IFS='|' read -r repo_file kind name ns <<< "$r"
  echo "Checking $kind/$name (repo: $repo_file)"
  if [ ! -f "$repo_file" ]; then
    echo "  ✖ Repo file $repo_file not found — skipping"
    had_drift=1
    continue
  fi

  # Render candidate canonical YAML from repo file if possible (use kubectl apply --dry-run=client when file appears to be plain YAML)
  if grep -q '{{' "$repo_file"; then
    echo "  ℹ️  Repository manifest contains templates (helm/kustomize markers); attempting limited rendering for namespace-only templates"
    # Attempt a minimal, deterministic render: substitute {{ .Release.Namespace }} with the target namespace when it is present
    if grep -q "{{ *\.Release\.Namespace *}}" "$repo_file" && [ -n "$ns" ]; then
      sed -E "s/\{\{ *\.Release\.Namespace *\}\}/$ns/g" "$repo_file" > "$TMPDIR/repo_rendered.yaml" || cp "$repo_file" "$TMPDIR/repo_rendered.yaml"
      echo "  ℹ️  Performed namespace substitution for template variables"
    else
      echo "  ⚠️  Repository manifest contains complex templates; exact comparison not possible without rendering. Marking as UNABLE_TO_COMPARE (advisory)"
      # Keep as advisory: emit warning but do not mark as drift failure
      cp "$repo_file" "$TMPDIR/repo_rendered.yaml"
      echo "  ⚠️  UNABLE_TO_COMPARE: $repo_file"
      continue
    fi
  else
    kubectl apply --server-side=false -f "$repo_file" --dry-run=client -o yaml > "$TMPDIR/repo_rendered.yaml" 2>/dev/null || cp "$repo_file" "$TMPDIR/repo_rendered.yaml"
  fi

  # Find live object
  if [ -n "$ns" ]; then
    if ! kubectl get "$kind" "$name" -n "$ns" >/dev/null 2>&1; then
      echo "  ✖ Live object $kind/$name in namespace $ns not found"
      had_drift=1
      continue
    fi
    kubectl get "$kind" "$name" -n "$ns" -o yaml > "$TMPDIR/live.yaml"
  else
    # search all namespaces for the named object
    found_ns=$(kubectl get "$kind" --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}:{.metadata.name}\n{end}' | awk -F: -v n="$name" '$2==n{print $1; exit}') || true
    if [ -z "$found_ns" ]; then
      echo "  ✖ Live object $kind/$name not found in any namespace"
      had_drift=1
      continue
    fi
    kubectl get "$kind" "$name" -n "$found_ns" -o yaml > "$TMPDIR/live.yaml"
  fi

  # Normalize both and diff
  repo_norm=$(mktemp)
  live_norm=$(mktemp)
  normalize < "$TMPDIR/repo_rendered.yaml" > "$repo_norm"
  normalize < "$TMPDIR/live.yaml" > "$live_norm"

  if ! diff -u "$repo_norm" "$live_norm" >/dev/null 2>&1; then
    echo "  ✖ Drift detected for $kind/$name"
    echo "  --- Diff ---"
    diff -u "$repo_norm" "$live_norm" | sed -n '1,200p'
    had_drift=1
  else
    echo "  ✔ No drift"
  fi
done

if [ "$had_drift" -ne 0 ]; then
  echo "\nDrift check completed: DRIFT DETECTED"
  if [ "$STRICT" -eq 1 ]; then
    echo "Strict mode: failing due to drift"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
  else
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
  fi
else
  echo "\nDrift check completed: no drift"
  exit 0
fi
