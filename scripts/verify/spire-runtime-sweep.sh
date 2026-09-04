#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# spire-runtime-sweep.sh — Task 6: Continuous runtime verification
#
# Periodically checks that:
# - ALL running sidecars have SPIFFE identity from /certs
# - ALL cert issuers are SPIRE
# - NO fallback CA artifacts are being used
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ENVOY_ADMIN_HELPER="$REPO_ROOT/scripts/lib/envoy_admin.sh"
INTERVAL_SECONDS="${SWEEP_INTERVAL:-300}"  # Default 5 minutes
LOG_FILE="${REPO_ROOT}/artifacts/debug/spire_runtime_sweep.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

fail_sweep() {
  log "[FAIL] $*"
  # Send alert but continue sweep cycle (don't exit)
  return 1
}

check_all_sidecars_have_spiffe_identity() {
  log "[sweep] checking all running sidecars have SPIFFE identity"

  local violations=0

  python3 - <<'PY' || return 1
import json, os, pathlib, subprocess, sys, tempfile

pods = json.loads(subprocess.check_output(["kubectl", "get", "pods", "-A", "-o", "json"], text=True))
violations = 0
envoy_admin_helper = os.environ["ENVOY_ADMIN_HELPER"]


def observe_certs(namespace, pod):
    with tempfile.TemporaryDirectory() as temp_dir:
        certs_path = pathlib.Path(temp_dir) / "certs.json"
        result = subprocess.run(
            ["bash", envoy_admin_helper, "capture-certs", namespace, pod, str(certs_path)],
            capture_output=True, text=True, timeout=15, check=False
        )
        if result.returncode != 0:
            print(f"[FAIL] {namespace}/{pod}: Envoy certificate observation UNOBSERVABLE")
            return None
        try:
            return json.loads(certs_path.read_text(encoding="utf-8"))
        except Exception as error:
            print(f"[FAIL] {namespace}/{pod}: malformed Envoy certificate observation: {error}")
            return None

for item in pods.get("items", []):
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})

    if status.get("phase") != "Running":
        continue
    if meta.get("deletionTimestamp"):
        continue

    containers = [c.get("name") for c in (spec.get("containers") or []) if isinstance(c, dict)]
    if "istio-proxy" not in containers:
        continue

    ns = meta.get("namespace", "")
    pod = meta.get("name", "")

    # Check for /certs SPIFFE identity
    certs = observe_certs(ns, pod)
    if certs is None:
        violations += 1
        continue

    try:
        has_spiffe = False
        for cert in certs.get("certificates", []) or []:
            for chain_cert in cert.get("cert_chain", []) or []:
                for san in chain_cert.get("subject_alt_names", []) or []:
                    if isinstance(san, dict) and san.get("uri", "").startswith("spiffe://"):
                        has_spiffe = True
                        break

        if not has_spiffe:
            print(f"[FAIL] {ns}/{pod}: no SPIFFE URI found in /certs")
            violations += 1
    except Exception as e:
        print(f"[FAIL] {ns}/{pod}: failed to inspect Envoy certificates: {e}")
        violations += 1

sys.exit(2 if violations > 0 else 0)
PY
}

check_all_sidecars_use_spire_issuer() {
  log "[sweep] checking all running sidecars use SPIRE issuer"

  python3 - <<'PY' || return 1
import json, os, subprocess, sys, base64, re, tempfile, pathlib

pods = json.loads(subprocess.check_output(["kubectl", "get", "pods", "-A", "-o", "json"], text=True))
violations = 0
envoy_admin_helper = os.environ["ENVOY_ADMIN_HELPER"]


def observe_secrets(namespace, pod):
    with tempfile.TemporaryDirectory() as temp_dir:
        secrets_path = pathlib.Path(temp_dir) / "secrets.json"
        result = subprocess.run(
            ["bash", envoy_admin_helper, "capture-secrets", namespace, pod, str(secrets_path)],
            capture_output=True, text=True, timeout=15, check=False
        )
        if result.returncode != 0:
            print(f"[FAIL] {namespace}/{pod}: Envoy SDS observation UNOBSERVABLE")
            return None
        try:
            return json.loads(secrets_path.read_text(encoding="utf-8"))
        except Exception as error:
            print(f"[FAIL] {namespace}/{pod}: malformed Envoy SDS observation: {error}")
            return None

def issuer_from_pem(pem):
    with tempfile.NamedTemporaryFile('w', delete=False) as f:
        f.write(pem)
        path = f.name
    try:
        result = subprocess.run(
            ["openssl", "x509", "-in", path, "-noout", "-issuer", "-nameopt", "RFC2253"],
            capture_output=True, text=True, check=False
        )
        if result.returncode == 0:
            return result.stdout.strip().split("=", 1)[-1].strip()
    finally:
        pathlib.Path(path).unlink(missing_ok=True)
    return None

for item in pods.get("items", []):
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    status = item.get("status", {})

    if status.get("phase") != "Running":
        continue
    if meta.get("deletionTimestamp"):
        continue

    containers = [c.get("name") for c in (spec.get("containers") or []) if isinstance(c, dict)]
    if "istio-proxy" not in containers:
        continue

    ns = meta.get("namespace", "")
    pod = meta.get("name", "")

    # Check SDS secret issuer
    secrets = observe_secrets(ns, pod)
    if secrets is None:
        violations += 1
        continue

    try:
        dynamic = secrets.get("dynamicActiveSecrets", [])
        default_entries = [secret for secret in dynamic if secret.get("name") == "default"]
        if len(default_entries) != 1:
            print(f"[FAIL] {ns}/{pod}: expected one default SDS secret, found {len(default_entries)}")
            violations += 1
            continue

        cert_b64 = (((default_entries[0].get("secret") or {}).get("tlsCertificate") or {})
                    .get("certificateChain") or {}).get("inlineBytes")
        if not cert_b64:
            print(f"[FAIL] {ns}/{pod}: default SDS secret missing certificate chain")
            violations += 1
            continue

        pem_text = base64.b64decode(cert_b64).decode("utf-8", errors="ignore")
        pems = re.findall(r"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----", pem_text)
        if not pems:
            print(f"[FAIL] {ns}/{pod}: default SDS secret has no parseable certificate")
            violations += 1
            continue

        issuer = issuer_from_pem(pems[0])
        if not issuer:
            print(f"[FAIL] {ns}/{pod}: unable to parse default SDS certificate issuer")
            violations += 1
            continue
        issuer_upper = issuer.upper()
        if "SPIRE" not in issuer_upper and "SPIFFE" not in issuer_upper:
            print(f"[FAIL] {ns}/{pod}: non-SPIRE issuer: {issuer}")
            violations += 1
        elif "THREADFORGE-ROOT" in issuer_upper or "CERT-MANAGER" in issuer_upper:
            print(f"[FAIL] {ns}/{pod}: forbidden issuer: {issuer}")
            violations += 1
    except Exception as e:
        print(f"[FAIL] {ns}/{pod}: failed to inspect SDS issuer: {e}")
        violations += 1

sys.exit(2 if violations > 0 else 0)
PY
}

check_no_fallback_artifacts_in_use() {
  log "[sweep] checking no legacy fallback artifacts are in use"

  # Check istio-ca-secret is not mounted anywhere
  local mounted_count
  mounted_count="$(kubectl get pods -A -o json \
    | jq '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running") | select(.spec.volumes[]? | select(.secret.secretName == "istio-ca-secret"))] | length')"

  if [[ "$mounted_count" -gt 0 ]]; then
    fail_sweep "istio-ca-secret is mounted in $mounted_count pods (must not be used)"
    return 1
  fi

  log "[sweep] no fallback artifacts in use"
}

run_continuous_sweep() {
  log "[sweep] starting continuous SPIRE runtime verification (interval: ${INTERVAL_SECONDS}s)"

  local sweep_count=0
  local violation_count=0

  while true; do
    sweep_count=$((sweep_count + 1))
    log "[sweep] cycle $sweep_count starting"

    if ! check_all_sidecars_have_spiffe_identity; then
      violation_count=$((violation_count + 1))
    fi

    if ! check_all_sidecars_use_spire_issuer; then
      violation_count=$((violation_count + 1))
    fi

    if ! check_no_fallback_artifacts_in_use; then
      violation_count=$((violation_count + 1))
    fi

    if [[ "$violation_count" -gt 0 ]]; then
      log "[ALERT] $violation_count violations detected in sweep cycle $sweep_count"
      violation_count=0
    else
      log "[sweep] cycle $sweep_count passed all checks"
    fi

    log "[sweep] waiting ${INTERVAL_SECONDS}s until next cycle"
    sleep "$INTERVAL_SECONDS"
  done
}

# If called with arguments, run once for testing; otherwise loop continuously
if [[ $# -eq 0 ]]; then
  run_continuous_sweep
else
  case "$1" in
    once)
      log "[sweep] running single verification cycle"
      failed=0
      check_all_sidecars_have_spiffe_identity || failed=1
      check_all_sidecars_use_spire_issuer || failed=1
      check_no_fallback_artifacts_in_use || failed=1
      exit "$failed"
      ;;
    *)
      echo "Usage: $0 [once]"
      exit 1
      ;;
  esac
fi
