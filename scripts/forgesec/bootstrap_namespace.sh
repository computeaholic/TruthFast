#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
namespace="${1:?namespace required}"
mode="${2:-isolated}"
registry_ca_cert_path="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
registry_server="${THREADFORGE_REGISTRY:-registry.threadforge.local:30500}"
registry_user="${THREADFORGE_REGISTRY_USER:-threadforge}"
registry_password="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"

if [[ "$mode" != "isolated" && "$mode" != "shared" ]]; then
  echo "[FAIL] unsupported FORGESEC mode: $mode" >&2
  exit 2
fi

render_manifest() {
  local source_path="$1"
  python3 - "$source_path" "$namespace" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
namespace = sys.argv[2]
text = re.sub(r'^(\s*namespace:\s*)forgesec\s*$', rf'\1{namespace}', text, flags=re.MULTILINE)
print(text, end="")
PY
}

if [[ "$mode" = "isolated" ]]; then
  render_manifest "$REPO_ROOT/platform/deploy/forgesec/namespace.yaml" | kubectl apply -f - >/dev/null
else
  kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace" >/dev/null
fi

kubectl label namespace "$namespace" istio-injection=enabled --overwrite >/dev/null

kubectl create configmap registry-ca \
  --namespace "$namespace" \
  --from-file=threadforge-ingress-ca.crt="$registry_ca_cert_path" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create secret docker-registry registry-credentials \
  --namespace "$namespace" \
  --docker-server="$registry_server" \
  --docker-username="$registry_user" \
  --docker-password="$registry_password" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

render_manifest "$REPO_ROOT/platform/deploy/forgesec/rbac.yaml" | kubectl apply -f - >/dev/null
render_manifest "$REPO_ROOT/platform/deploy/forgesec/workers-reader-role.yaml" | kubectl apply -f - >/dev/null
kubectl patch serviceaccount forgesec-sa -n "$namespace" -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' >/dev/null 2>&1 || true

if [[ "$mode" = "isolated" ]]; then
  render_manifest "$REPO_ROOT/platform/deploy/forgesec/networkpolicy.yaml" | kubectl apply -f - >/dev/null
fi
