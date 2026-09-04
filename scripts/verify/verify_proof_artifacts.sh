#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"
# shellcheck source=scripts/lib/proof_artifact_manifest.sh
source "$REPO_ROOT/scripts/lib/proof_artifact_manifest.sh"
PROOF_DIR="${1:-$REPO_ROOT/artifacts/proof/latest}"
PROOF_STATUS_FILE="${PROOF_STATUS_FILE:-$PROOF_DIR/status.json}"
COSIGN_PUBLIC_KEY="${COSIGN_PUBLIC_KEY:-${HOME}/.threadforge-signing/cosign.pub}"
VERIFY_TLOG_REQUIRED="${VERIFY_TLOG_REQUIRED:-true}"
VERIFY_INVARIANTS="${VERIFY_INVARIANTS:-true}"
COSIGN_VERIFY_TIMEOUT_SECONDS="${COSIGN_VERIFY_TIMEOUT_SECONDS:-30}"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
export SPIFFE_TRUST_DOMAIN

if [ "${2:-}" != "" ]; then
  COSIGN_PUBLIC_KEY="$2"
fi

if ! command -v cosign >/dev/null 2>&1; then
  echo "[FAIL] cosign not found in PATH"
  exit 2
fi
if [ ! -d "$PROOF_DIR" ]; then
  echo "[FAIL] proof directory not found: $PROOF_DIR"
  exit 2
fi
if [ ! -f "$COSIGN_PUBLIC_KEY" ]; then
  echo "[FAIL] cosign public key not found: $COSIGN_PUBLIC_KEY"
  exit 2
fi
if [ "$VERIFY_TLOG_REQUIRED" != "true" ]; then
  echo "[FAIL] VERIFY_TLOG_REQUIRED=false is forbidden — transparency log verification is mandatory"
  fail_policy "VERIFY_TLOG_REQUIRED=false is not permitted"
fi
if [ "$VERIFY_INVARIANTS" != "true" ] && [ "$VERIFY_INVARIANTS" != "false" ]; then
  echo "[FAIL] VERIFY_INVARIANTS must be true or false (got: $VERIFY_INVARIANTS)"
  fail_policy "invalid VERIFY_INVARIANTS"
fi
if [ "$VERIFY_INVARIANTS" = "false" ]; then
  echo "[FAIL] CONTRACT_VIOLATION: VERIFY_INVARIANTS=false is not permitted — proof invariant verification is mandatory"
  fail_policy "VERIFY_INVARIANTS=false is forbidden"
fi

# Verifies a blob using the local transparency bundle only. This must not
# contact Rekor or depend on network availability during proof finalization.
_verify_blob() {
  local file="$1"
  local bundle="${file}.bundle.json"
  if [ ! -s "$bundle" ]; then
    fail_policy "tlog bundle missing: ${file##*/}.bundle.json — transparency log verification is mandatory"
  fi
  timeout "${COSIGN_VERIFY_TIMEOUT_SECONDS}s" cosign verify-blob \
    --offline \
    --key "$COSIGN_PUBLIC_KEY" \
    --bundle "$bundle" \
    "$file" >/dev/null
}

print_summary() {
  printf 'VERIFY_SIGNATURES=%s\n' "$VERIFY_SIGNATURES_STATUS"
  printf 'VERIFY_DIGESTS=%s\n' "$VERIFY_DIGESTS_STATUS"
  printf 'VERIFY_INVARIANTS=%s\n' "$VERIFY_INVARIANTS_STATUS"
  printf 'FINAL_VERIFICATION=%s\n' "$FINAL_VERIFICATION_STATUS"
}

VERIFY_SIGNATURES_STATUS="FAIL"
VERIFY_DIGESTS_STATUS="FAIL"
VERIFY_INVARIANTS_STATUS="FAIL"
FINAL_VERIFICATION_STATUS="FAIL"

# Canonical latest artifact set includes verify.norm.log, observe.log,
# observability.json, workload_projection_continuity.json, determinism.json,
# ca_integrity.json, and optional gateway_ca_source.json / failure_behavior.json /
# existing_session_fail_closed.json / sidecar_enforcement_validation.json via
# proof_artifact_manifest.sh.

files=()
while IFS= read -r artifact_name; do
  files+=("$PROOF_DIR/$artifact_name")
done < <(proof_latest_artifact_names "$PROOF_DIR")

hash_manifest="$PROOF_DIR/hashes.txt"
if [ ! -s "$hash_manifest" ]; then
  fail_policy "missing proof hash manifest"
fi

if [ ! -s "${hash_manifest}.sig" ]; then
  fail_policy "missing proof hash manifest signature"
fi

_verify_blob "$hash_manifest" \
  || fail_policy "hash manifest signature invalid: hashes.txt"

sha256_file() {
  local file="$1"
  sha256sum "$file" | awk '{print "sha256:" $1}'
}

_verify_count=0
for file in "${files[@]}"; do
  sig="${file}.sig"
  if [ ! -f "$file" ]; then
    echo "[FAIL] proof artifact missing: $file"
    fail_policy "missing proof artifact: ${file##*/}"
  fi
  if [ ! -s "$sig" ]; then
    echo "[FAIL] signature missing: $sig"
    fail_policy "missing proof signature: ${file##*/}.sig"
  fi
  _verify_blob "$file" \
    || fail_policy "signature invalid: ${file##*/}"
  _verify_count=$(( _verify_count + 1 ))
done

if ! (
  cd "$PROOF_DIR"
  sha256sum -c hashes.txt >/dev/null
); then
  fail_policy "proof artifacts modified after signing"
fi

root_status="$REPO_ROOT/artifacts/proof/status.json"
root_status_sig="${root_status}.sig"
if [ ! -f "$root_status" ]; then
  fail_policy "missing authoritative root status.json"
fi
if [ ! -s "$root_status_sig" ]; then
  fail_policy "missing authoritative root status signature"
fi
timeout "${COSIGN_VERIFY_TIMEOUT_SECONDS}s" cosign verify-blob \
  --key "$COSIGN_PUBLIC_KEY" \
  --signature "$root_status_sig" \
  "$root_status" >/dev/null || fail_policy "signature invalid: authoritative status.json"

echo "[PASS] verified $(( _verify_count + 1 )) proof artifacts (signatures valid)"

VERIFY_SIGNATURES_STATUS="PASS"

set +e
python3 - "$PROOF_DIR" "$PROOF_STATUS_FILE" "${files[@]}" <<'PY'
import hashlib
import json
import pathlib
import sys

proof_dir = pathlib.Path(sys.argv[1])
status_path = pathlib.Path(sys.argv[2])
artifact_paths = [pathlib.Path(arg) for arg in sys.argv[3:]]


def sha256_file(path: pathlib.Path) -> str:
  return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()

doc = json.loads(status_path.read_text())
completion_record = doc.get("completion_record")
if completion_record is not None and not isinstance(completion_record, dict):
  raise SystemExit("completion_record must be a JSON object when present")

canonical = completion_record if isinstance(completion_record, dict) else doc
if isinstance(completion_record, dict):
  identity = completion_record.get("identity")
  if not isinstance(identity, dict):
    raise SystemExit("missing completion_record.identity block")
  for field in ("operation_id", "producer"):
    if not isinstance(identity.get(field), str) or not identity.get(field, "").strip():
      raise SystemExit(f"completion_record.identity missing required field: {field}")
  outcome = completion_record.get("outcome")
  if not isinstance(outcome, dict):
    raise SystemExit("missing completion_record.outcome block")
  for field in ("status", "proof_result", "fail_class"):
    if not isinstance(outcome.get(field), str) or not outcome.get(field, "").strip():
      raise SystemExit(f"completion_record.outcome missing required field: {field}")
  if not isinstance(completion_record.get("artifacts"), dict):
    raise SystemExit("missing completion_record.artifacts block")

evidence = canonical.get("evidence")
if not isinstance(evidence, dict):
  raise SystemExit("missing evidence block in completion record")

artifacts = evidence.get("artifacts")
if not isinstance(artifacts, dict):
  raise SystemExit("missing evidence.artifacts block in completion record")

if isinstance(completion_record, dict):
  if doc.get("evidence") != canonical.get("evidence"):
    raise SystemExit("completion_record evidence is not aligned with top-level status.json projection")
  if doc.get("guarantees") != canonical.get("guarantees"):
    raise SystemExit("completion_record guarantees is not aligned with top-level status.json projection")
  if doc.get("final") != canonical.get("outcome", {}).get("status"):
    raise SystemExit("completion_record outcome.status is not aligned with top-level final")
  if doc.get("fail_class") != canonical.get("outcome", {}).get("fail_class"):
    raise SystemExit("completion_record outcome.fail_class is not aligned with top-level fail_class")
  if doc.get("proof_result") != canonical.get("outcome", {}).get("proof_result"):
    raise SystemExit("completion_record outcome.proof_result is not aligned with top-level proof_result")

status_sha_expected = artifacts.get("status.json")

for path in artifact_paths:
  expected = artifacts.get("status.json") if path == status_path else artifacts.get(path.name)
  if path == status_path:
    continue
  if expected != sha256_file(path):
    raise SystemExit(f"{path.name} digest mismatch")

work = json.loads(status_path.read_text())
work.setdefault("evidence", {}).setdefault("artifacts", {})["status.json"] = ""
completion_record = work.get("completion_record")
if isinstance(completion_record, dict):
  completion_record.setdefault("evidence", {}).setdefault("artifacts", {})["status.json"] = ""
  completion_record.setdefault("artifacts", {})["status.json"] = ""
canonical = json.dumps(work, sort_keys=True, separators=(",", ":")).encode("utf-8")
status_sha_actual = "sha256:" + hashlib.sha256(canonical).hexdigest()
if status_sha_expected != status_sha_actual:
  raise SystemExit("status.json digest mismatch")

for field in ("cluster_id",):
  value = doc.get(field)
  if not isinstance(value, str) or not value.strip():
    raise SystemExit(f"missing required replay-context field: {field}")

print("[PASS] digest binding validated for signed proof artifacts")
PY
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  fail_policy "signed proof artifact digest binding mismatch"
fi

VERIFY_DIGESTS_STATUS="PASS"

if [ "$VERIFY_INVARIANTS" = "true" ]; then
  set +e
  _det_arg="$PROOF_DIR/determinism.json"
  [ -f "$_det_arg" ] || _det_arg=""
  _ca_arg=""
  [ -f "$PROOF_DIR/ca_integrity.json" ] && _ca_arg="$PROOF_DIR/ca_integrity.json"
  _workload_projection_arg="$PROOF_DIR/workload_projection_continuity.json"
  [ -f "$_workload_projection_arg" ] || _workload_projection_arg=""
  python3 - "$PROOF_DIR" "$PROOF_STATUS_FILE" "$PROOF_DIR/verify.log" "$PROOF_DIR/observe.log" "$_workload_projection_arg" "$_ca_arg" "$PROOF_DIR/gateway_ca_source.json" "$PROOF_DIR/failure_behavior.json" "$PROOF_DIR/existing_session_fail_closed.json" "$PROOF_DIR/sidecar_enforcement_validation.json" "$_det_arg" <<'PY'
import json
import os
import pathlib
import sys

proof_dir = pathlib.Path(sys.argv[1])
status_path = pathlib.Path(sys.argv[2])
verify_log_path = pathlib.Path(sys.argv[3])
observe_log_path = pathlib.Path(sys.argv[4])
workload_projection_continuity_path = pathlib.Path(sys.argv[5]) if sys.argv[5] else None
ca_integrity_path = pathlib.Path(sys.argv[6]) if sys.argv[6] else None
gateway_ca_source_path = pathlib.Path(sys.argv[7])
failure_behavior_path = pathlib.Path(sys.argv[8])
existing_session_path = pathlib.Path(sys.argv[9])
sidecar_enforcement_path = pathlib.Path(sys.argv[10])
determinism_path = pathlib.Path(sys.argv[11]) if sys.argv[11] else None

status = json.loads(status_path.read_text())
completion_record = status.get("completion_record")
if isinstance(completion_record, dict):
  canonical = completion_record
else:
  canonical = status
final_status = status.get("final")
if final_status not in {"PASS", "FAIL"}:
  raise SystemExit(f"status invariant failed: final={final_status!r} expected 'PASS' or 'FAIL'")

if final_status == "FAIL":
  if status.get("signed") is not True:
    raise SystemExit("status invariant failed: signed is not true")
  if status.get("verified") is not True:
    raise SystemExit("status invariant failed: verified is not true")
  evidence = status.get("evidence")
  if not isinstance(evidence, dict):
    raise SystemExit("status invariant failed: evidence block missing")
  if evidence.get("signed") is not True:
    raise SystemExit("status invariant failed: evidence.signed is not true")
  if evidence.get("verified") is not True:
    raise SystemExit("status invariant failed: evidence.verified is not true")
  fail_class = status.get("fail_class")
  if not isinstance(fail_class, str) or not fail_class.strip() or fail_class == "NONE":
    raise SystemExit(f"status invariant failed: fail_class={fail_class!r} invalid for failed proof")
  print("[PASS] failure-state artifact invariants validated")
  raise SystemExit(0)

required_top = {
  "final": "PASS",
  "fail_class": "NONE",
  "envoy_identity": "PASS",
  "cluster_integrity": "PASS",
  "observability_prereq": "PASS",
  "observability": "PASS",
  "verify": "PASS",
  "observe": "PASS",
}
for key, expected in required_top.items():
  actual = status.get(key)
  if actual != expected:
    raise SystemExit(f"status invariant failed: {key}={actual!r} expected {expected!r}")

for phase_key in ("bootstrap", "identity"):
  phase = status.get(phase_key)
  if not isinstance(phase, dict) or phase.get("status") != "PASS":
    raise SystemExit(f"status invariant failed: {phase_key}.status is not PASS")

if status.get("signed") is not True:
  raise SystemExit("status invariant failed: signed is not true")
if status.get("verified") is not True:
  raise SystemExit("status invariant failed: verified is not true")

evidence = status.get("evidence")
if not isinstance(evidence, dict):
  raise SystemExit("status invariant failed: evidence block missing")
if evidence.get("signed") is not True:
  raise SystemExit("status invariant failed: evidence.signed is not true")
if evidence.get("verified") is not True:
  raise SystemExit("status invariant failed: evidence.verified is not true")

observe_text = observe_log_path.read_text()
required_observe_markers = (
  "START authoritative observe phase",
  "START validate_observability",
  "PASS check=stack_liveness",
  "PASS check=signal_emission",
  "PASS check=signal_query_loki",
  "PASS check=signal_query_tempo",
  "PASS check=cross_system_correlation",
  "END validate_observability status=PASS",
)
for marker in required_observe_markers:
  if marker not in observe_text:
    raise SystemExit(f"observe invariant failed: missing marker {marker!r}")

verify_text = verify_log_path.read_text()
if "CONTRACT_VIOLATION" in verify_text:
  raise SystemExit("verify invariant failed: CONTRACT_VIOLATION present in verify.log")
if "[FAIL]" in verify_text:
  raise SystemExit("verify invariant failed: [FAIL] entry present in verify.log")

if workload_projection_continuity_path is not None:
  workload_projection_continuity = json.loads(workload_projection_continuity_path.read_text())
  if workload_projection_continuity.get("status") != "PASS":
    raise SystemExit("workload_projection_continuity invariant failed: status is not PASS")
  if workload_projection_continuity.get("fail_class") is not None:
    raise SystemExit("workload_projection_continuity invariant failed: fail_class must be null")
  for key in ("producer", "consumer", "identity_chain", "projections"):
    if key not in workload_projection_continuity:
      raise SystemExit(f"workload_projection_continuity invariant failed: missing {key}")
  identity_chain = workload_projection_continuity.get("identity_chain")
  if not isinstance(identity_chain, dict):
    raise SystemExit("workload_projection_continuity invariant failed: identity_chain must be an object")
  for key in ("canonical", "rendered", "applied", "running"):
    if key not in identity_chain:
      raise SystemExit(f"workload_projection_continuity invariant failed: missing identity_chain.{key}")

if ca_integrity_path is not None:
  ca_integrity = json.loads(ca_integrity_path.read_text())
  if ca_integrity.get("single_root") is not True:
    raise SystemExit("ca_integrity invariant failed: single_root is not true")
  if len({ca_integrity.get("spire_root_hash"), ca_integrity.get("istio_root_hash"), ca_integrity.get("envoy_root_hash")}) != 1:
    raise SystemExit("ca_integrity invariant failed: trust root hashes do not match")

gateway_ca_source = json.loads(gateway_ca_source_path.read_text())
if gateway_ca_source.get("status") != "PASS":
  raise SystemExit("gateway_ca_source invariant failed: status is not PASS")
if gateway_ca_source.get("citadel_log_artifacts") is not False:
  raise SystemExit("gateway_ca_source invariant failed: Citadel artifacts detected")
if gateway_ca_source.get("single_runtime_root") is not True:
  raise SystemExit("gateway_ca_source invariant failed: single_runtime_root is not true")
if gateway_ca_source.get("spire_root_hash") != gateway_ca_source.get("gateway_root_hash"):
  raise SystemExit("gateway_ca_source invariant failed: gateway root hash does not match SPIRE root")
issuer_line = str(gateway_ca_source.get("issuer_line", ""))
leaf_issuer = str(gateway_ca_source.get("leaf_issuer", ""))
if gateway_ca_source.get("spiffe_san_match") is not True:
  raise SystemExit("gateway_ca_source invariant failed: spiffe_san_match is not true")
san_uris = gateway_ca_source.get("leaf_san_uris") or []
if not any(isinstance(uri, str) and uri.startswith("spiffe://" + os.environ["SPIFFE_TRUST_DOMAIN"] + "/") for uri in san_uris):
  raise SystemExit("gateway_ca_source invariant failed: leaf SAN URIs do not include a valid SPIFFE identity")
if issuer_line and ("threadforge.local" not in issuer_line.lower() and "threadforge" not in issuer_line.lower()):
  raise SystemExit("gateway_ca_source invariant failed: issuer_line present but does not reflect ThreadForge trust")

if failure_behavior_path.exists():
  failure_behavior = json.loads(failure_behavior_path.read_text())
  spire_outage_state = failure_behavior.get("spire_outage")
  if spire_outage_state not in ("validated", "policy_blocked"):
    raise SystemExit(f"failure_behavior invariant failed: spire_outage must be 'validated' or 'policy_blocked', got '{spire_outage_state}'")
  if spire_outage_state == "validated" and failure_behavior.get("new_connections") != "fail":
    raise SystemExit("failure_behavior invariant failed: when spire_outage=validated, new_connections must be fail")
  if failure_behavior.get("cert_issuance") != "blocked":
    raise SystemExit("failure_behavior invariant failed: cert_issuance not blocked")

if existing_session_path.exists():
  existing_session = json.loads(existing_session_path.read_text())
  spire_outage_state_session = existing_session.get("spire_outage")
  if spire_outage_state_session not in ("validated", "policy_blocked"):
    raise SystemExit(f"existing_session_fail_closed invariant failed: spire_outage must be 'validated' or 'policy_blocked', got '{spire_outage_state_session}'")
  if spire_outage_state_session == "validated":
    if existing_session.get("existing_session") != "fail_closed":
      raise SystemExit("existing_session_fail_closed invariant failed: when spire_outage=validated, existing_session must be fail_closed")
    if existing_session.get("fresh_request_after_expiry") != "fail":
      raise SystemExit("existing_session_fail_closed invariant failed: when spire_outage=validated, fresh_request_after_expiry must be fail")

if sidecar_enforcement_path.exists():
  sidecar_enforcement = json.loads(sidecar_enforcement_path.read_text())
  if sidecar_enforcement.get("status") != "PASS":
    raise SystemExit("sidecar_enforcement invariant failed: status is not PASS")
  if sidecar_enforcement.get("running_pod_scan", {}).get("status") != "PASS":
    raise SystemExit("sidecar_enforcement invariant failed: running_pod_scan did not PASS")
  if sidecar_enforcement.get("running_pod_scan", {}).get("violations"):
    raise SystemExit("sidecar_enforcement invariant failed: protected namespace pod violations detected")
  valid_pod = sidecar_enforcement.get("valid_injected_pod", {})
  if valid_pod.get("status") != "PASS":
    raise SystemExit("sidecar_enforcement invariant failed: valid_injected_pod did not PASS")
  if "istio-proxy" not in (valid_pod.get("containers") or []):
    raise SystemExit("sidecar_enforcement invariant failed: valid injected pod missing istio-proxy")

east_west_isolation_path = proof_dir / "east_west_isolation.json"
if east_west_isolation_path.exists():
  east_west_isolation = json.loads(east_west_isolation_path.read_text())
  if east_west_isolation.get("status") != "PASS":
    raise SystemExit("east_west_isolation invariant failed: status is not PASS")
  for key in (
    "blocked_threadforge_test_to_prometheus",
    "allowed_threadforge_test_to_echo",
    "allowed_observability_to_prometheus",
  ):
    if east_west_isolation.get(key, {}).get("status") != "PASS":
      raise SystemExit(f"east_west_isolation invariant failed: {key} did not PASS")

north_south_boundary_path = proof_dir / "north_south_boundary.json"
if north_south_boundary_path.exists():
  north_south_boundary = json.loads(north_south_boundary_path.read_text())
  if north_south_boundary.get("status") != "PASS":
    raise SystemExit("north_south_boundary invariant failed: status is not PASS")
  for key in (
    "nodeport_audit",
    "direct_nodeport_blocked",
    "unauthorized_ingress_denied",
    "allowed_ingress_path",
    "direct_pod_ip_blocked",
    "external_egress_blocked",
    "registry_anonymous_denied",
    "registry_authenticated_allowed",
  ):
    if north_south_boundary.get(key, {}).get("status") != "PASS":
      raise SystemExit(f"north_south_boundary invariant failed: {key} did not PASS")

root_lifecycle_status_path = proof_dir / "root_lifecycle_status.json"
if root_lifecycle_status_path.exists():
  root_lifecycle = json.loads(root_lifecycle_status_path.read_text())
  for key in (
    "continuity_ok",
    "coverage_gap_detected",
    "successor_count",
    "state",
    "spire_lifecycle_ok",
    "continuous_successor_policy_ok",
    "prepare_due",
    "activate_due",
    "continuity_state",
  ):
    if key not in root_lifecycle:
      raise SystemExit(f"root_lifecycle_status invariant failed: missing {key}")
  if root_lifecycle.get("spire_lifecycle_ok") is not True:
    raise SystemExit("root_lifecycle_status invariant failed: spire_lifecycle_ok must be true")
  if not isinstance(root_lifecycle.get("continuity_ok"), bool):
    raise SystemExit("root_lifecycle_status invariant failed: continuity_ok must be bool")
  if not isinstance(root_lifecycle.get("coverage_gap_detected"), bool):
    raise SystemExit("root_lifecycle_status invariant failed: coverage_gap_detected must be bool")
  if not isinstance(root_lifecycle.get("successor_count"), int):
    raise SystemExit("root_lifecycle_status invariant failed: successor_count must be int")
  if not isinstance(root_lifecycle.get("spire_lifecycle_ok"), bool):
    raise SystemExit("root_lifecycle_status invariant failed: spire_lifecycle_ok must be bool")
  if not isinstance(root_lifecycle.get("continuous_successor_policy_ok"), bool):
    raise SystemExit("root_lifecycle_status invariant failed: continuous_successor_policy_ok must be bool")
  if not isinstance(root_lifecycle.get("prepare_due"), bool):
    raise SystemExit("root_lifecycle_status invariant failed: prepare_due must be bool")
  if not isinstance(root_lifecycle.get("activate_due"), bool):
    raise SystemExit("root_lifecycle_status invariant failed: activate_due must be bool")
  if root_lifecycle.get("state") not in {"healthy", "warning", "critical", "exhausted"}:
    raise SystemExit("root_lifecycle_status invariant failed: state invalid")
  if root_lifecycle.get("continuity_state") not in {"ACTIVE_ONLY", "ACTIVE_PLUS_PREPARED", "PREPARE_DUE", "ROTATING", "VIOLATION"}:
    raise SystemExit("root_lifecycle_status invariant failed: continuity_state invalid")

successor_root_validation_path = proof_dir / "successor_root_validation.json"
if root_lifecycle.get("prepare_due") is True:
  if not successor_root_validation_path.exists():
    raise SystemExit("successor_root_validation invariant failed: missing successor_root_validation.json when prepare_due is true")
  successor_validation = json.loads(successor_root_validation_path.read_text())
  for key in (
    "continuity_ok",
    "successor_count",
    "successor_published",
    "successor_key_available",
    "successor_overlap_valid",
    "bundle_publication_valid",
    "key_availability_valid",
    "lifecycle_continuity_preserved",
    "spire_lifecycle_ok",
    "continuous_successor_policy_ok",
    "prepare_due",
    "activate_due",
    "continuity_state",
  ):
    if key not in successor_validation:
      raise SystemExit(f"successor_root_validation invariant failed: missing {key}")
  if successor_validation.get("spire_lifecycle_ok") is not True:
    raise SystemExit("successor_root_validation invariant failed: spire_lifecycle_ok must be true")
  if successor_validation.get("continuous_successor_policy_ok") is not True:
    raise SystemExit("successor_root_validation invariant failed: continuous_successor_policy_ok must be true")
  if not isinstance(successor_validation.get("successor_count"), int):
    raise SystemExit("successor_root_validation invariant failed: successor_count must be int")
  if successor_validation.get("successor_count", 0) < 1:
    raise SystemExit("successor_root_validation invariant failed: successor_count must be >= 1")
  for key in (
    "successor_published",
    "successor_key_available",
    "successor_overlap_valid",
    "bundle_publication_valid",
    "key_availability_valid",
    "lifecycle_continuity_preserved",
  ):
    if successor_validation.get(key) is not True:
      raise SystemExit(f"successor_root_validation invariant failed: {key} must be true")

determinism = json.loads(determinism_path.read_text()) if determinism_path else None
if determinism is not None:
  if determinism.get("consistent") is not True:
    raise SystemExit("determinism invariant failed: consistent is not true")
  if determinism.get("fail_class") != "NONE":
    raise SystemExit("determinism invariant failed: fail_class is not NONE")

# ---------------------------------------------------------------------------
# Guarantee block validation — every guarantee must PASS and canonical proof
# must not carry blocked guarantee paths.
# ---------------------------------------------------------------------------
REQUIRED_GUARANTEES = [
  "fail_closed_execution",
  "deterministic_output",
  "no_fallback_logic",
  "no_optional_paths",
  "identity_spiffe",
  "identity_envoy",
  "supply_chain_digest",
  "kind_node_image_verified",
  "runtime_identity_verified",
  "no_external_images",
  "admission_enforced",
  "observability_stack",
  "observability_behavior",
  "workload_projection_continuity",
  "trust_root_immutability",
  "registry_tls_trust",
  "registry_completeness",
  "mesh_baseline",
  "north_south_boundary",
  "east_west_isolation",
  "sidecar_enforcement",
  "service_topology",
  "rbac_resolution",
  "audit_logging",
  "tenant_isolation",
  "cert_rotation_continuity",
  "existing_session_fail_closed",
  "no_istio_ca_fallback",
]
guarantees = canonical.get("guarantees")
if not isinstance(guarantees, dict):
  raise SystemExit("missing guarantees block in completion record")
for g in REQUIRED_GUARANTEES:
  if g not in guarantees:
    raise SystemExit(f"missing guarantee in status.json: {g}")
  entry = guarantees[g]
  if not isinstance(entry, dict):
    raise SystemExit(f"guarantee entry malformed: {g}")
  g_status = entry.get("status")
  if g_status != "PASS":
    raise SystemExit(f"guarantee has invalid status: {g}={g_status!r}")
  if not entry.get("phase"):
    raise SystemExit(f"guarantee missing phase: {g}")
  if not entry.get("enforced_by"):
    raise SystemExit(f"guarantee missing enforced_by: {g}")

passive = status.get("passive_guarantees", status.get("read_only_guarantees"))
read_only = status.get("read_only_guarantees")
active = status.get("active_guarantees")
blocked = status.get("blocked_guarantees")
if passive != "PASS":
  raise SystemExit(f"passive_guarantees must be PASS, got {passive!r}")
if read_only is not None and read_only != passive:
  raise SystemExit("deprecated read_only_guarantees alias must equal passive_guarantees")
if active != "PASS":
  raise SystemExit(f"active_guarantees must be PASS, got {active!r}")
if status.get("proof_heals_canonical_state") not in (None, False):
  raise SystemExit("proof_heals_canonical_state must not be true")
if not isinstance(blocked, list):
  raise SystemExit("blocked_guarantees must be a list")
if blocked:
  raise SystemExit(f"blocked_guarantees must be empty, got {blocked!r}")

print(f"[PASS] guarantee truth model validated for {len(REQUIRED_GUARANTEES)} guarantees")
print(f"PASSIVE_GUARANTEES={passive}")
if read_only is not None:
  print(f"READ_ONLY_GUARANTEES={read_only}")
print(f"ACTIVE_GUARANTEES={active}")

print("[PASS] invariant re-check validated status.json, verify.log, and observe.log")
PY
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fail_policy "proof invariants failed"
  fi
  VERIFY_INVARIANTS_STATUS="PASS"
fi

FINAL_VERIFICATION_STATUS="PASS"

print_summary
