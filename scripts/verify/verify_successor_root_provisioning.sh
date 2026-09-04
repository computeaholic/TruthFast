#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_JSON="${SUCCESSOR_VALIDATION_JSON:-$REPO_ROOT/artifacts/trust/successor_root_validation.json}"
OUT_METRICS="${SUCCESSOR_METRICS_PATH:-$REPO_ROOT/artifacts/trust/successor_root_metrics.prom}"
ROOT_STATUS_JSON="$REPO_ROOT/artifacts/trust/root_lifecycle_status.json"

if bash "$REPO_ROOT/scripts/verify/verify_root_lifecycle_continuity.sh"; then
  rc=0
else
  rc=$?
fi

mkdir -p "$(dirname "$OUT_JSON")" "$(dirname "$OUT_METRICS")"

if [[ ! -f "$ROOT_STATUS_JSON" ]]; then
  cat >"$OUT_JSON" <<'JSON'
{
  "active_root_present": false,
  "bundle_publication_valid": false,
  "continuity_ok": false,
  "coverage_gap_detected": true,
  "errors": ["missing root lifecycle status"],
  "key_availability_valid": false,
  "lifecycle_continuity_preserved": false,
  "successor_count": 0,
  "successor_key_available": false,
  "successor_overlap_valid": false,
  "successor_published": false
}
JSON
  exit 2
fi

python3 - "$ROOT_STATUS_JSON" "$OUT_JSON" <<'PY'
import json
import sys
from pathlib import Path

root_status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
spire_native = root_status.get("spire_native_lifecycle") or {}
predicates = root_status.get("spire_native_continuity_predicates") or {}
continuity_ok = bool(root_status.get("continuity_ok"))
continuous_successor_policy_ok = bool(root_status.get("continuous_successor_policy_ok"))
spire_lifecycle_ok = bool(root_status.get("spire_lifecycle_ok"))
successor_count = int(root_status.get("successor_count") or 0)
prepared = spire_native.get("prepared_authority_state") or []

payload = {
    "authority": "spire-server-own-trust-domain-bundle",
    "mutation_performed": False,
    "active_root_present": bool(spire_native.get("active_authority_state")),
    "active_root_serial": root_status.get("active_root_serial", ""),
    "successor_count": successor_count,
    "successor_published": predicates.get("prepared_published") is True,
    "successor_key_available": predicates.get("prepared_key_present") is True,
    "successor_overlap_valid": predicates.get("overlap_exists") is True,
    "bundle_publication_valid": predicates.get("prepared_published") is True,
    "key_availability_valid": predicates.get("prepared_key_present") is True,
    "lifecycle_continuity_preserved": continuous_successor_policy_ok,
    "continuity_ok": continuous_successor_policy_ok,
    "continuous_successor_policy_ok": continuous_successor_policy_ok,
    "spire_lifecycle_ok": spire_lifecycle_ok,
    "prepare_due": bool(root_status.get("prepare_due")),
    "activate_due": bool(root_status.get("activate_due")),
    "continuity_state": root_status.get("continuity_state", "UNKNOWN"),
    "coverage_gap_detected": bool(root_status.get("coverage_gap_detected")),
    "minimum_successor_count": root_status.get("minimum_successor_count", 1),
    "minimum_overlap_hours": root_status.get("minimum_overlap_hours", 12),
    "prepared_authority_state": prepared,
    "spire_native_continuity_predicates": predicates,
    "root_lifecycle_status_source": "artifacts/trust/root_lifecycle_status.json",
    "errors": [] if continuous_successor_policy_ok else ["continuous successor policy predicates failed"],
}
Path(sys.argv[2]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

continuity_ok="$(jq -r '.continuity_ok // false' "$OUT_JSON")"
spire_lifecycle_ok="$(jq -r '.spire_lifecycle_ok // false' "$OUT_JSON")"
successor_count="$(jq -r '.successor_count // 0' "$OUT_JSON")"
successor_published="$(jq -r '.successor_published // false' "$OUT_JSON")"
successor_key_available="$(jq -r '.successor_key_available // false' "$OUT_JSON")"
successor_overlap_valid="$(jq -r '.successor_overlap_valid // false' "$OUT_JSON")"
prepare_due="$(jq -r '.prepare_due // false' "$OUT_JSON")"

cat >"$OUT_METRICS" <<EOF
# HELP threadforge_trust_successor_generation_total Total generated successor trust roots by ThreadForge. Always zero; SPIRE owns generation.
# TYPE threadforge_trust_successor_generation_total counter
threadforge_trust_successor_generation_total 0
# HELP threadforge_trust_successor_generation_failures_total Total failed successor validation/provisioning observations.
# TYPE threadforge_trust_successor_generation_failures_total counter
threadforge_trust_successor_generation_failures_total $([[ "$continuity_ok" == "true" ]] && echo 0 || echo 1)
# HELP threadforge_trust_bundle_root_count Number of roots in authoritative SPIRE bundle.
# TYPE threadforge_trust_bundle_root_count gauge
threadforge_trust_bundle_root_count $(jq -r '.roots | length' "$ROOT_STATUS_JSON")
EOF

echo "[verify_successor_root] successor_count=$successor_count successor_published=$successor_published successor_key_available=$successor_key_available successor_overlap_valid=$successor_overlap_valid spire_lifecycle_ok=$spire_lifecycle_ok continuous_successor_policy_ok=$continuity_ok" >&2

if [[ "$prepare_due" != "true" ]]; then
  echo "[PASS] CONTRACT_VIOLATION: successor root provisioning not yet due" >&2
  exit 0
fi

if [[ "$rc" -ne 0 || "$continuity_ok" != "true" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: successor root provisioning validation failed" >&2
  exit 2
fi
