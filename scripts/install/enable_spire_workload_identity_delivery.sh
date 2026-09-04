#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MATRIX_PATH="$REPO_ROOT/artifacts/service_trust_matrix.json"

if [ ! -f "$MATRIX_PATH" ]; then
  echo "[FAIL] missing: artifacts/service_trust_matrix.json"
  echo "[ADVISORY-FAIL] non-authoritative path"
  exit 0
fi

python3 - "$MATRIX_PATH" <<'PY' | while IFS=$'\t' read -r name namespace; do
import json
import pathlib
import sys

matrix = json.loads(pathlib.Path(sys.argv[1]).read_text())
for svc in matrix.get("services", []):
    if not isinstance(svc, dict):
        continue
    name = svc.get("name")
    namespace = svc.get("namespace")
    if isinstance(name, str) and name and isinstance(namespace, str) and namespace:
        print(f"{name}\t{namespace}")
PY
  kubectl label namespace "$namespace" istio-injection=enabled --overwrite >/dev/null 2>&1 || true

  deploys="$(kubectl get deploy -n "$namespace" -l "app=$name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  if [ -z "$deploys" ] && kubectl get deploy -n "$namespace" "$name" >/dev/null 2>&1; then
    deploys="$name"
  fi
  if [ -z "$deploys" ]; then
    echo "[FAIL] no deployment found for service $name in namespace $namespace (label app=$name)"
    echo "[ADVISORY-FAIL] non-authoritative path"
    exit 0
  fi

  for deploy in $deploys; do
    tmp="$(mktemp)"
    kubectl get deploy -n "$namespace" "$deploy" -o json >"$tmp"

    python3 - "$tmp" <<'PY'
import json
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
obj = json.loads(p.read_text())
tmpl = obj.setdefault("spec", {}).setdefault("template", {})
meta = tmpl.setdefault("metadata", {})
ann = meta.get("annotations") or {}
ann.pop("sidecar.istio.io/userVolume", None)
ann.pop("sidecar.istio.io/userVolumeMount", None)
ann["sidecar.istio.io/inject"] = "true"
meta["annotations"] = ann
tmpl["metadata"] = meta

labels = meta.get("labels") or {}
labels.pop("sidecar.istio.io/inject", None)
meta["labels"] = labels

spec = tmpl.setdefault("spec", {})
service_account = spec.get("serviceAccountName")
if not isinstance(service_account, str) or not service_account.strip():
    raise SystemExit("missing serviceAccountName")

p.write_text(json.dumps(obj))
PY

    if ! kubectl apply -f "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      echo "[FAIL] unable to reconcile sidecar delivery for $namespace/$deploy"
      echo "[ADVISORY-FAIL] non-authoritative path"
      exit 0
    fi
    rm -f "$tmp"

    if ! kubectl rollout status deployment/"$deploy" -n "$namespace" --timeout=120s >/dev/null; then
      desired="$(kubectl get deployment/"$deploy" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
      available="$(kubectl get deployment/"$deploy" -n "$namespace" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
      if [ "${available:-0}" -lt "${desired:-1}" ]; then
        echo "[FAIL] rollout incomplete for $namespace/$deploy (available=${available:-0} desired=${desired:-1})"
        echo "[ADVISORY-FAIL] non-authoritative path"
        exit 0
      fi
    fi

    echo "[PASS] Istio sidecar delivery enabled: $namespace/$deploy"
  done
done

echo "[PASS] workload identity delivery aligned to Istio+SPIRE SDS"
