#!/usr/bin/env bash
set -euo pipefail

namespace="${FORGESEC_NAMESPACE:-forgesec}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found in PATH" >&2
  exit 127
fi

# Best-effort cleanup of ForgeSec transient runtime objects.  The delete
# operations are intentionally authoritative: already-absent resources are
# tolerated via --ignore-not-found, but real kubectl failures still propagate.
kubectl delete jobs -n "$namespace" -l app=forgesec --ignore-not-found >/dev/null
kubectl delete pods -n "$namespace" -l app=forgesec --ignore-not-found >/dev/null
