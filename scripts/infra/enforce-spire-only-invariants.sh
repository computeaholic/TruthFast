#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# enforce-spire-only-invariants.sh — Structural anti-regression guarantees
#
# Tasks:
# - Task 3: Enforce istiod config source (spire-ca-root-cert)
# - Task 4: Add bootstrap invariants
# - Task 5: Enforce SDS requirement
# - Task 8: Lock rotation behavior
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
export ENVOY_ADMIN_HELPER="$REPO_ROOT/scripts/lib/envoy_admin.sh"

fail() {
  echo "[FAIL] SPIRE-only invariant violated: $*"
  exit 2
}

# ========================================================================
# Task 3: Enforce istiod config source (ALWAYS spire-ca-root-cert)
# ========================================================================
enforce_istiod_root_source() {
  echo "[invariant] enforcing istiod root source = spire-ca-root-cert"

  local current_source
  current_source="$(kubectl -n istio-system get deployment istiod -o json \
    | jq -r '.spec.template.spec.volumes[] | select(.name == "istio-csr-ca-configmap") | .configMap.name' 2>/dev/null || true)"

  if [[ "$current_source" != "spire-ca-root-cert" ]]; then
    echo "[invariant] patching istiod root source from '${current_source}' to 'spire-ca-root-cert'"
    kubectl -n istio-system get deployment istiod -o json \
      | jq '(.spec.template.spec.volumes[] | select(.name == "istio-csr-ca-configmap") | .configMap.name) = "spire-ca-root-cert"' \
      | kubectl apply -f - >/dev/null
    kubectl -n istio-system rollout restart deployment/istiod >/dev/null
    kubectl -n istio-system rollout status deployment/istiod --timeout=180s >/dev/null
  fi

  # Verify it took effect
  current_source="$(kubectl -n istio-system get deployment istiod -o json \
    | jq -r '.spec.template.spec.volumes[] | select(.name == "istio-csr-ca-configmap") | .configMap.name')"
  [[ "$current_source" == "spire-ca-root-cert" ]] || fail "istiod root source still not spire-ca-root-cert after patch"
}

# ========================================================================
# Task 4: Assert bootstrap invariants
# ========================================================================
assert_spire_root_available() {
  echo "[invariant] asserting SPIRE root bundle is available"

  local spire_root_pem
  spire_root_pem="$(kubectl -n spire-system exec spire-server-0 -- /opt/spire/bin/spire-server bundle show \
    -socketPath /run/spire/private/spire-server.sock -format pem 2>/dev/null || true)"

  [[ -n "$spire_root_pem" ]] || fail "SPIRE root bundle unavailable"
}

assert_spire_ca_root_cert_populated() {
  echo "[invariant] asserting spire-ca-root-cert configmap has valid root"

  local root_cert_len
  root_cert_len="$(kubectl -n istio-system get configmap spire-ca-root-cert -o json 2>/dev/null \
    | jq -r '.data["root-cert.pem"] | length')"

  [[ "$root_cert_len" -gt 100 ]] || fail "spire-ca-root-cert configmap root cert is empty or missing"
}

assert_no_legacy_ca_secrets_in_use() {
  echo "[invariant] asserting no legacy CA secrets are mounted in istiod"

  local uses_legacy
  uses_legacy="$(kubectl -n istio-system get deployment istiod -o json \
    | jq '(.spec.template.spec.volumes // [])
      | any(.[]?; ((.secret.secretName // "") == "istio-ca-secret") or ((.secret.secretName // "") == "threadforge-root-ca"))')"

  [[ "$uses_legacy" != "true" ]] || fail "istiod still uses legacy CA secret volumes"
}

assert_istiod_root_file_non_empty() {
  echo "[invariant] asserting istiod root cert file is non-empty"

  local istiod_pod cert_len
  istiod_pod="$(kubectl -n istio-system get pod -l app=istiod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$istiod_pod" ]] || fail "no istiod pod found"

  cert_len="$(kubectl -n istio-system exec "$istiod_pod" -- wc -c /var/run/secrets/istiod/ca/root-cert.pem \
    | awk '{print $1}' || true)"

  [[ "$cert_len" -gt 100 ]] || fail "istiod mounted root cert file is empty (size=$cert_len)"
}

# ========================================================================
# Task 5: Enforce SDS requirement for all injected workloads
# ========================================================================
assert_all_injected_workloads_have_sds() {
  echo "[invariant] asserting all injected workloads are configured for SDS"

  python3 - <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import tempfile

pods = json.loads(subprocess.check_output(["kubectl", "get", "pods", "-A", "-o", "json"], text=True))
envoy_admin_helper = os.environ["ENVOY_ADMIN_HELPER"]


def observe_envoy(kind, namespace, pod):
    with tempfile.TemporaryDirectory() as temp_dir:
        output_path = pathlib.Path(temp_dir) / f"{kind}.json"
        proc = subprocess.run(
            ["bash", envoy_admin_helper, f"capture-{kind}", namespace, pod, str(output_path)],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        if proc.returncode != 0:
            label = "SDS" if kind == "secrets" else "certificate"
            print(f"[FAIL] {namespace}/{pod}: Envoy {label} observation UNOBSERVABLE")
            sys.exit(2)
        try:
            return json.loads(output_path.read_text(encoding="utf-8"))
        except Exception:
            label = "SDS" if kind == "secrets" else "certificate"
            print(f"[FAIL] {namespace}/{pod}: malformed Envoy {label} observation")
            sys.exit(2)

for item in pods.get("items", []):
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})

    # Skip non-running pods
    if status.get("phase") != "Running":
        continue
    if meta.get("deletionTimestamp"):
        continue

    # Find istio-proxy container
    containers = [c.get("name") for c in (spec.get("containers") or []) if isinstance(c, dict)]
    if "istio-proxy" not in containers:
        continue

    ns = meta.get("namespace", "")
    pod = meta.get("name", "")

    # Runtime SDS check: default cert chain exists and includes SPIFFE URI.
    secret_doc = observe_envoy("secrets", ns, pod)

    dynamic = secret_doc.get("dynamicActiveSecrets") or []
    static = secret_doc.get("staticSecrets") or []
    if static:
      print(f"[FAIL] {ns}/{pod}: static identity secrets bypass SDS rotation")
      sys.exit(2)
    default_entries = [x for x in dynamic if isinstance(x, dict) and x.get("name") == "default"]
    if len(default_entries) != 1:
      print(f"[FAIL] {ns}/{pod}: expected one default SDS secret, found {len(default_entries)}")
      sys.exit(2)

    chain_b64 = ((((default_entries[0].get("secret") or {}).get("tlsCertificate") or {}).get("certificateChain") or {}).get("inlineBytes"))
    if not chain_b64:
      print(f"[FAIL] {ns}/{pod}: default SDS secret missing certificate chain")
      sys.exit(2)

    certs_doc = observe_envoy("certs", ns, pod)

    has_spiffe = False
    for cert in certs_doc.get("certificates", []) or []:
      for chain_cert in cert.get("cert_chain", []) or []:
        for san in chain_cert.get("subject_alt_names", []) or []:
          if isinstance(san, dict) and isinstance(san.get("uri"), str) and san["uri"].startswith("spiffe://"):
            has_spiffe = True
            break
        if has_spiffe:
          break
      if has_spiffe:
        break

    if not has_spiffe:
      print(f"[FAIL] {ns}/{pod}: no SPIFFE URI in active certificate chain")
      sys.exit(2)

print("[invariant] all injected workloads properly configured for SPIRE SDS")
PY
}

# ========================================================================
# Task 8: Lock rotation behavior (ensure live rotation via SDS)
# ========================================================================
assert_rotation_configured_via_sds() {
  echo "[invariant] asserting certificate rotation is configured via SDS"

  local mesh_config ready_replicas endpoint_count
  mesh_config="$(kubectl -n istio-system get configmap istio -o jsonpath='{.data.mesh}' 2>/dev/null || true)"
  printf '%s\n' "$mesh_config" | grep -Eq '^[[:space:]]+ISTIO_META_CERT_SIGNER:[[:space:]]+spire-csr[[:space:]]*$' \
    || fail "Istio mesh does not configure spire-csr as the certificate signer"

  ready_replicas="$(kubectl -n istio-system get deployment spire-csr -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ "${ready_replicas:-0}" -ge 1 ]] || fail "spire-csr signer deployment is not ready"

  endpoint_count="$(kubectl -n istio-system get endpoints spire-csr -o json 2>/dev/null \
    | jq '[.subsets[]?.addresses[]?] | length' || true)"
  [[ "${endpoint_count:-0}" -ge 1 ]] || fail "spire-csr signer service has no ready endpoints"
}

# ========================================================================
# Main invariant enforcement
# ========================================================================
main() {
  echo "[invariant] beginning SPIRE-only structural enforcement"

  # Task 3: Config source
  enforce_istiod_root_source

  # Task 4: Bootstrap assertions
  assert_spire_root_available
  assert_spire_ca_root_cert_populated
  assert_no_legacy_ca_secrets_in_use
  assert_istiod_root_file_non_empty

  # Task 5: SDS requirement
  assert_all_injected_workloads_have_sds

  # Task 8: Rotation behavior
  assert_rotation_configured_via_sds

  echo "[invariant] all SPIRE-only structural invariants satisfied"
}

main "$@"
