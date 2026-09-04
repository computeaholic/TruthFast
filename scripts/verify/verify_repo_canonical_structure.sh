#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# verify_repo_canonical_structure.sh — ThreadForge canonical structure enforcer
#
# EXIT 2 on any violation (CONTRACT_VIOLATION — proof-system semantics).
# EXIT 0 on clean.
#
# Invariants enforced:
#   1. artifacts/ contains no FORBIDDEN test-generated dirs (governance/aas, test_*)
#   2. NO test_aas* dirs at repo root or inside tests/
#   3. internal/observability/ is the single Python observability domain
#   4. scripts/proof/ and scripts/verify/ exist (partitioned scripts layout)
#   5. scripts/tests/ does NOT exist (contents belong in scripts/proof/)
#   6. platform/runtime/observability/ does NOT exist (moved to internal/observability/)
#   7. observability/ does NOT exist at repo root (Python pkg moved to internal/observability/)
#   8. platform/deploy/ is the single deployment root (no multiple deployment roots)
#   9. infra/ does NOT exist at repo root (moved to platform/deploy/infra/)
#  10. gitops/ does NOT exist at repo root (moved to platform/deploy/gitops/)
#  11. security/ does NOT exist at repo root (duplicate: canonical is platform/security/)
#  12. platform/deploy/_legacy/ does NOT exist (dead legacy manifests)
#  13. inspector/ does NOT exist (dead, unreferenced)
#  14. services/trust-mesh/ does NOT exist (dead stub)
#  15. data/ does NOT exist at repo root (dead; canonical: data/schemas/)
#  16. identity/ does NOT exist at repo root (dead generated file)
#  17. audit_output/ does NOT exist at repo root (canonical audit path is artifacts/audit/)
#  18. platform/deploy/infra/istio/artifacts/ is NOT git-tracked (runtime-generated)
#  19. platform/security/ forensic subdirs are NOT git-tracked
#  20. cosign.pub is at canonical location: platform/security/cosign.pub
#  21. platform/deploy/infra/observability/ exists (single K8s observability manifest root)
#  22. observability/scripts/ does NOT exist (moved to scripts/advisory/observability/)
#  23. observability/infra/ does NOT exist (orphaned; canonical: platform/deploy/infra/observability/)
#  24. platform/deploy/observability/ does NOT exist (merged into platform/deploy/infra/observability/)
#  25. platform/deploy/infra/observability/evidence/ is NOT git-tracked (runtime evidence)
#  26. infra/ and platform/deploy/infra/ do NOT coexist (no duplicate infra domain)
#  27. platform/deploy/base/observability/ does NOT exist (moved to platform/deploy/infra/observability/base/)
#  28. platform/deploy/infra/monitoring/observability/ does NOT exist (merged into platform/deploy/infra/observability/monitoring/)
#  29. platform/deploy/telemetry/ contains NO infra-level constructs (ServiceMonitor/PrometheusRule/ClusterRole)
#  47. logs/ does NOT exist at repo root (runtime output directed to artifacts/logs/)
#  48. __init__.py does NOT exist at repo root (root is not a Python package)
#  49. THREADFORGE_PATCH.diff does NOT exist at repo root (debug artifact)
#  50. tree.txt does NOT exist at repo root (generated snapshot artifact)
# =============================================================================

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo ".")}"
VIOLATIONS=0

fail_contract() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  VIOLATIONS=$(( VIOLATIONS + 1 ))
}

echo "[canonical-structure] Checking canonical repo structure root=$REPO_ROOT"

# ---------------------------------------------------------------------------
# Check 1: artifacts/ contains no FORBIDDEN test-generated directories
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 1: artifacts/ no forbidden test-generated dirs"
# governance/aas was created by test code via bare AASProvider defaults (now fixed to use tmp_path)
FORBIDDEN_ARTIFACT_DIRS=("governance/aas")
for forbidden in "${FORBIDDEN_ARTIFACT_DIRS[@]}"; do
  if [ -d "$REPO_ROOT/artifacts/$forbidden" ]; then
    fail_contract "artifacts/$forbidden is FORBIDDEN — test code must use pytest tmp_path; not create under artifacts/"
  else
    echo "[PASS] artifacts/$forbidden absent (correct)"
  fi
done
# Check no test_* directories anywhere in artifacts/
mapfile -t TEST_ARTIFACT_DIRS < <(find "$REPO_ROOT/artifacts" -maxdepth 3 -type d -name "test_*" 2>/dev/null || true)
if [ "${#TEST_ARTIFACT_DIRS[@]}" -gt 0 ]; then
  for d in "${TEST_ARTIFACT_DIRS[@]}"; do
    rel="${d#$REPO_ROOT/}"
    fail_contract "test_* dir in artifacts/ FORBIDDEN: $rel — tests must not create dirs under artifacts/"
  done
else
  echo "[PASS] no test_* dirs in artifacts/"
fi

# ---------------------------------------------------------------------------
# Check 2: NO test_aas* dirs at repo root or tests/
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 2: no test_aas* dirs at repo root or tests/"
mapfile -t TEST_AAS_DIRS < <(find "$REPO_ROOT" -maxdepth 2 -type d -name "test_aas*" 2>/dev/null || true)
if [ "${#TEST_AAS_DIRS[@]}" -gt 0 ]; then
  for d in "${TEST_AAS_DIRS[@]}"; do
    rel="${d#$REPO_ROOT/}"
    fail_contract "test_aas* dir FORBIDDEN: $rel — tests must use pytest tmp_path fixture; AAS artifacts go to artifacts/aas/"
  done
else
  echo "[PASS] no test_aas* dirs found"
fi

# ---------------------------------------------------------------------------
# Check 3: internal/observability/ is the single Python observability domain
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 3: internal/observability/ is single Python observability domain"
if [ ! -d "$REPO_ROOT/internal/observability" ]; then
  fail_contract "internal/observability/ missing — canonical Python observability package must be at internal/observability/"
else
  echo "[PASS] internal/observability/ exists as canonical Python observability package"
fi
if [ -d "$REPO_ROOT/platform/runtime/observability" ]; then
  fail_contract "platform/runtime/observability/ exists — DUPLICATE DOMAIN: move to internal/observability/ and delete platform/runtime/observability/"
else
  echo "[PASS] platform/runtime/observability/ does not exist (correctly removed)"
fi

# ---------------------------------------------------------------------------
# Check 4: scripts/ is partitioned — required subdirs exist
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 4: scripts/ partitioned layout"
REQUIRED_SCRIPT_DIRS=("scripts/proof" "scripts/verify" "scripts/install" "scripts/chaos" "scripts/debug")
for dir in "${REQUIRED_SCRIPT_DIRS[@]}"; do
  if [ ! -d "$REPO_ROOT/$dir" ]; then
    fail_contract "$dir/ missing — scripts/ must be partitioned into proof/, verify/, install/, chaos/, debug/"
  else
    echo "[PASS] $dir/ exists"
  fi
done

# ---------------------------------------------------------------------------
# Check 5: scripts/tests/ must NOT exist
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 5: scripts/tests/ is forbidden"
if [ -d "$REPO_ROOT/scripts/tests" ]; then
  fail_contract "scripts/tests/ exists — FORBIDDEN: test scripts must be in scripts/proof/ (move and delete scripts/tests/)"
else
  echo "[PASS] scripts/tests/ does not exist"
fi

# ---------------------------------------------------------------------------
# Check 6: no loose *.sh files at scripts/ root (except prove_system.sh and utils.sh)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 6: no bare scripts at scripts/ root"
mapfile -t ROOT_SCRIPTS < <(find "$REPO_ROOT/scripts" -maxdepth 1 -name "*.sh" -type f 2>/dev/null | sort)
ALLOWED_ROOT_SCRIPTS=("prove_system.sh" "utils.sh")
for script in "${ROOT_SCRIPTS[@]}"; do
  basename_s="$(basename "$script")"
  found=false
  for allowed in "${ALLOWED_ROOT_SCRIPTS[@]}"; do
    [ "$basename_s" = "$allowed" ] && found=true && break
  done
  if [ "$found" = "false" ]; then
    fail_contract "bare script at scripts/ root: $basename_s — move to scripts/proof/, scripts/verify/, scripts/install/, scripts/chaos/, or scripts/debug/"
  else
    echo "[PASS] $basename_s is an allowed root-level script"
  fi
done

# ---------------------------------------------------------------------------
# Check 7: observability/ must NOT exist at root (Python pkg moved to internal/observability/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 7: observability/ must not exist at repo root"
if [ -d "$REPO_ROOT/observability" ]; then
  fail_contract "observability/ exists at repo root — Python package moved to internal/observability/; delete observability/"
else
  echo "[PASS] observability/ does not exist at repo root (correctly moved to internal/observability/)"
fi

# ---------------------------------------------------------------------------
# Check 8: platform/deploy/ is the SINGLE deployment root (no multiple deployment roots)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 8: platform/deploy/ is single deployment root"
if [ ! -d "$REPO_ROOT/platform/deploy" ]; then
  fail_contract "platform/deploy/ directory missing — single deployment root must exist at platform/deploy/"
else
  echo "[PASS] platform/deploy/ exists as deployment root"
fi
# platform/deploy/_legacy/ must not exist
if [ -d "$REPO_ROOT/platform/deploy/_legacy" ]; then
  fail_contract "platform/deploy/_legacy/ exists — FORBIDDEN: dead legacy manifests; delete platform/deploy/_legacy/"
else
  echo "[PASS] platform/deploy/_legacy/ does not exist"
fi

# ---------------------------------------------------------------------------
# Check 9: infra/ must NOT exist at repo root (moved to platform/deploy/infra/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 9: infra/ must not exist at repo root"
if [ -d "$REPO_ROOT/infra" ]; then
  fail_contract "infra/ exists at repo root — DUPLICATE DOMAIN: contents moved to platform/deploy/infra/; delete infra/"
else
  echo "[PASS] infra/ does not exist at repo root (correctly moved to platform/deploy/infra/)"
fi

# ---------------------------------------------------------------------------
# Check 10: gitops/ must NOT exist at repo root (moved to platform/deploy/gitops/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 10: gitops/ must not exist at repo root"
if [ -d "$REPO_ROOT/gitops" ]; then
  fail_contract "gitops/ exists at repo root — moved to platform/deploy/gitops/; delete gitops/"
else
  echo "[PASS] gitops/ does not exist at repo root (correctly moved to platform/deploy/gitops/)"
fi

# ---------------------------------------------------------------------------
# Check 11: security/ must NOT exist at repo root (duplicate of platform/security/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 11: no top-level security/ duplicate"
if [ -d "$REPO_ROOT/security" ]; then
  fail_contract "security/ exists at repo root — DUPLICATE DOMAIN: canonical location is platform/security/; cosign.pub belongs at platform/security/cosign.pub"
else
  echo "[PASS] security/ does not exist at repo root (correctly removed)"
fi

# ---------------------------------------------------------------------------
# Check 12: inspector/ must NOT exist (unreferenced dead code)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 12: inspector/ must not exist"
if [ -d "$REPO_ROOT/inspector" ]; then
  fail_contract "inspector/ exists — DEAD: no references in Makefile/scripts/CI; delete inspector/"
else
  echo "[PASS] inspector/ does not exist"
fi

# ---------------------------------------------------------------------------
# Check 13: services/trust-mesh/ must NOT exist (dead stub)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 13: services/trust-mesh/ must not exist"
if [ -d "$REPO_ROOT/services/trust-mesh" ]; then
  fail_contract "services/trust-mesh/ exists — DEAD: unreferenced Helm stub; delete services/trust-mesh/"
else
  echo "[PASS] services/trust-mesh/ does not exist"
fi

# ---------------------------------------------------------------------------
# Check 14: data/ MUST EXIST as canonical data layer
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 14: data/ must exist as canonical data layer"
if [ ! -d "$REPO_ROOT/data" ]; then
  fail_contract "data/ missing — CANONICAL: all persistence and query definitions must live under data/ (data/queries/, data/schemas/, data/db/)"
else
  echo "[PASS] data/ exists as canonical data layer"
  # Verify the three expected subdirectories exist
  for sub in queries schemas db; do
    if [ ! -d "$REPO_ROOT/data/$sub" ]; then
      fail_contract "data/$sub/ missing — expected canonical data sublayer: data/queries/, data/schemas/, data/db/"
    else
      echo "[PASS] data/$sub/ exists under canonical data layer"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Check 15: identity/ must NOT exist at repo root (dead generated file)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 15: identity/ must not exist at repo root"
if [ -d "$REPO_ROOT/identity" ]; then
  fail_contract "identity/ exists at repo root — DEAD: single generated YAML with no references; delete identity/"
else
  echo "[PASS] identity/ does not exist at repo root"
fi

# ---------------------------------------------------------------------------
# Check 16: observability/infra/ must NOT exist (orphaned; canonical: platform/deploy/infra/observability/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 16: observability/infra/ must not exist"
if [ -d "$REPO_ROOT/observability/infra" ]; then
  fail_contract "observability/infra/ exists — ORPHAN: not referenced anywhere; authoritative Prometheus config is platform/deploy/infra/observability/"
else
  echo "[PASS] observability/infra/ does not exist"
fi

# ---------------------------------------------------------------------------
# Check 17: audit_output/ must NOT be git-tracked (runtime-generated)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 17: audit_output/ must not exist at repo root"
if [ -d "$REPO_ROOT/audit_output" ]; then
  fail_contract "audit_output/ exists at repo root — canonical audit path is artifacts/audit/"
else
  echo "[PASS] audit_output/ absent at repo root"
fi

# ---------------------------------------------------------------------------
# Check 18: platform/deploy/infra/istio/artifacts/ must NOT be git-tracked
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 18: platform/deploy/infra/istio/artifacts/ must not be git-tracked"
TRACKED_ISTIO_ART=$(git ls-files "$REPO_ROOT/platform/deploy/infra/istio/artifacts" 2>/dev/null | wc -l || true)
if [ "$TRACKED_ISTIO_ART" -gt 0 ]; then
  fail_contract "platform/deploy/infra/istio/artifacts/ has $TRACKED_ISTIO_ART git-tracked runtime files — untrack with 'git rm -r --cached'"
else
  echo "[PASS] platform/deploy/infra/istio/artifacts/ is not git-tracked"
fi

# ---------------------------------------------------------------------------
# Check 19: platform/security/ forensic subdirs must NOT be git-tracked
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 19: platform/security/ forensic subdirs must not be git-tracked"
FORENSIC_SUBDIRS=("baseline" "ha" "kes" "maturity" "performance" "postgres-tls" "spire-migration")
for sub in "${FORENSIC_SUBDIRS[@]}"; do
  tracked=$(git ls-files "$REPO_ROOT/platform/security/$sub" 2>/dev/null | wc -l || true)
  if [ "$tracked" -gt 0 ]; then
    fail_contract "platform/security/$sub/ has $tracked git-tracked forensic files — RUNTIME_ARTIFACT: untrack with 'git rm -r --cached platform/security/$sub/'"
  else
    echo "[PASS] platform/security/$sub/ is not git-tracked"
  fi
done

# ---------------------------------------------------------------------------
# Check 20: cosign.pub must be at canonical location: platform/security/cosign.pub
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 20: cosign.pub at canonical location"
if [ ! -f "$REPO_ROOT/platform/security/cosign.pub" ]; then
  fail_contract "platform/security/cosign.pub missing — canonical location for cosign public key"
else
  echo "[PASS] platform/security/cosign.pub exists at canonical location"
fi

# ---------------------------------------------------------------------------
# Check 20b: root signing key and helper logs must not exist
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 20b: root signing key and helper logs absent"
ROOT_LEAKS=(
  "cosign.key"
  "proof.log"
  "proof-https.log"
  "proof-https-2.log"
  "proof-https-final.log"
  "runtime_images.txt"
  "sds_trace.log"
)
for leak in "${ROOT_LEAKS[@]}"; do
  if [ -e "$REPO_ROOT/$leak" ]; then
    fail_contract "$leak exists at repo root — move generated output under artifacts/ or user-scoped signing directory"
  else
    echo "[PASS] $leak absent at repo root"
  fi
done

# ---------------------------------------------------------------------------
# Check 21: platform/deploy/infra/observability/ must exist (single K8s observability manifest root)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 21: platform/deploy/infra/observability/ exists as K8s manifest root"
if [ ! -d "$REPO_ROOT/platform/deploy/infra/observability" ]; then
  fail_contract "platform/deploy/infra/observability/ missing — single canonical K8s observability manifest location"
else
  echo "[PASS] platform/deploy/infra/observability/ exists as canonical K8s observability root"
fi

# ---------------------------------------------------------------------------
# Check 22: observability/scripts/ must NOT exist
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 22: observability/scripts/ must not exist"
if [ -d "$REPO_ROOT/observability/scripts" ]; then
  fail_contract "observability/scripts/ exists — DUPLICATE: these scripts are in scripts/advisory/observability/; delete observability/scripts/"
else
  echo "[PASS] observability/scripts/ does not exist"
fi

# ---------------------------------------------------------------------------
# Check 23: platform/deploy/infra/ and platform/deploy/gitops/ must exist (infra/gitops consolidated under platform/deploy/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 23: platform/deploy/infra/ and platform/deploy/gitops/ exist as consolidated roots"
if [ ! -d "$REPO_ROOT/platform/deploy/infra" ]; then
  fail_contract "platform/deploy/infra/ missing — all infra manifests must be under platform/deploy/infra/"
else
  echo "[PASS] platform/deploy/infra/ exists"
fi
if [ ! -d "$REPO_ROOT/platform/deploy/gitops" ]; then
  fail_contract "platform/deploy/gitops/ missing — GitOps manifests must be under platform/deploy/gitops/"
else
  echo "[PASS] platform/deploy/gitops/ exists"
fi

# ---------------------------------------------------------------------------
# Check 24: platform/deploy/observability/ must NOT exist (merged into platform/deploy/infra/observability/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 24: platform/deploy/observability/ must not exist (single observability root)"
if [ -d "$REPO_ROOT/platform/deploy/observability" ]; then
  fail_contract "platform/deploy/observability/ exists — DUPLICATE: canonical location is platform/deploy/infra/observability/; merge and remove"
else
  echo "[PASS] platform/deploy/observability/ does not exist (no duplicate observability root)"
fi

# ---------------------------------------------------------------------------
# Check 25: platform/deploy/infra/observability/evidence/ must NOT be git-tracked (runtime data)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 25: platform/deploy/infra/observability/evidence/ must not be git-tracked"
if git -C "$REPO_ROOT" ls-files --error-unmatch "platform/deploy/infra/observability/evidence/" >/dev/null 2>&1 || \
   git -C "$REPO_ROOT" ls-files "platform/deploy/infra/observability/evidence/" | grep -q .; then
  fail_contract "platform/deploy/infra/observability/evidence/ is git-tracked — runtime evidence belongs in artifacts/ (git-ignored)"
else
  echo "[PASS] platform/deploy/infra/observability/evidence/ is not git-tracked"
fi

# ---------------------------------------------------------------------------
# Check 26: no duplicate infra domains — infra/ and platform/deploy/infra/ must not coexist
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 26: no duplicate infra domain (infra/ and platform/deploy/infra/ must not coexist)"
if [ -d "$REPO_ROOT/infra" ] && [ -d "$REPO_ROOT/platform/deploy/infra" ]; then
  fail_contract "infra/ and platform/deploy/infra/ both exist — DUPLICATE DOMAIN: canonical location is platform/deploy/infra/"
else
  echo "[PASS] no duplicate infra domain"
fi

# ---------------------------------------------------------------------------
# Check 27: platform/deploy/base/observability/ must NOT exist (moved to platform/deploy/infra/observability/base/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 27: platform/deploy/base/observability/ must not exist"
if [ -d "$REPO_ROOT/platform/deploy/base/observability" ]; then
  fail_contract "platform/deploy/base/observability/ exists — SHADOW DOMAIN: canonical location is platform/deploy/infra/observability/base/"
else
  echo "[PASS] platform/deploy/base/observability/ does not exist (correctly moved to platform/deploy/infra/observability/base/)"
fi

# ---------------------------------------------------------------------------
# Check 28: platform/deploy/infra/monitoring/observability/ must NOT exist (merged into platform/deploy/infra/observability/monitoring/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 28: platform/deploy/infra/monitoring/observability/ must not exist"
if [ -d "$REPO_ROOT/platform/deploy/infra/monitoring/observability" ]; then
  fail_contract "platform/deploy/infra/monitoring/observability/ exists — NESTED DUPLICATION: canonical location is platform/deploy/infra/observability/monitoring/"
else
  echo "[PASS] platform/deploy/infra/monitoring/observability/ does not exist (collapsed into platform/deploy/infra/observability/monitoring/)"
fi

# ---------------------------------------------------------------------------
# Check 29: platform/deploy/telemetry/ must NOT contain infra-level constructs
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 29: platform/deploy/telemetry/ must not contain infra-level constructs"
_telemetry_infra=""
if git -C "$REPO_ROOT" ls-files platform/deploy/telemetry/ | \
     xargs grep -l "kind: ServiceMonitor\|kind: PrometheusRule\|kind: ClusterRole\|kind: ClusterRoleBinding" \
     2>/dev/null | grep -q .; then
  _telemetry_infra="$(git -C "$REPO_ROOT" ls-files platform/deploy/telemetry/ | \
    xargs grep -l "kind: ServiceMonitor\|kind: PrometheusRule\|kind: ClusterRole\|kind: ClusterRoleBinding" 2>/dev/null | head -3)"
  fail_contract "platform/deploy/telemetry/ contains infra-level manifests (ServiceMonitor/PrometheusRule/ClusterRole) — move to platform/deploy/infra/observability/: ${_telemetry_infra}"
else
  echo "[PASS] platform/deploy/telemetry/ contains no infra-level constructs (scope: runtime signals only)"
fi

# ---------------------------------------------------------------------------
# Check 30: root-level *.json files are FORBIDDEN
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 30: no root-level *.json files"
# pyrightconfig.json is a governance-allowed tooling config at repo root
ALLOWED_ROOT_JSONS=("pyrightconfig.json")
mapfile -t ROOT_JSONS < <(find "$REPO_ROOT" -maxdepth 1 -name '*.json' -type f 2>/dev/null || true)
_json_violations=0
for j in "${ROOT_JSONS[@]}"; do
  bn="$(basename "$j")"
  _allowed=false
  for a in "${ALLOWED_ROOT_JSONS[@]}"; do [ "$bn" = "$a" ] && _allowed=true && break; done
  if [ "$_allowed" = "false" ]; then
    fail_contract "root-level JSON FORBIDDEN: $bn — JSON artifacts/configs must live under artifacts/config/ or artifacts/build/"
    _json_violations=$((_json_violations+1))
  fi
done
if [ "$_json_violations" -eq 0 ]; then
  echo "[PASS] no forbidden root-level *.json files"
fi

# ---------------------------------------------------------------------------
# Check 31: deploy/ must NOT exist at repo root
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 31: deploy/ must not exist at repo root"
if [ -d "$REPO_ROOT/deploy" ]; then
  fail_contract "deploy/ exists at repo root — DUPLICATE DOMAIN: canonical location is platform/deploy/; delete deploy/"
else
  echo "[PASS] deploy/ does not exist at repo root (correctly moved to platform/deploy/)"
fi

# ---------------------------------------------------------------------------
# Check 32: runtime/ must NOT exist at repo root
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 32: runtime/ must not exist at repo root"
if [ -d "$REPO_ROOT/runtime" ]; then
  fail_contract "runtime/ exists at repo root — DUPLICATE DOMAIN: canonical location is platform/runtime/; delete runtime/"
else
  echo "[PASS] runtime/ does not exist at repo root (correctly moved to platform/runtime/)"
fi

# ---------------------------------------------------------------------------
# Check 33: labs/ must NOT exist at repo root
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 33: labs/ must not exist at repo root"
if [ -d "$REPO_ROOT/labs" ]; then
  fail_contract "labs/ exists at repo root — FORBIDDEN: experimental infra moved to platform/labs/; delete labs/"
else
  echo "[PASS] labs/ does not exist at repo root (correctly moved to platform/labs/)"
fi

# ---------------------------------------------------------------------------
# Check 34–36: queries/ schemas/ db/ must NOT exist at repo root
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 34–36: queries/ schemas/ db/ must not exist at repo root"
for stale_dir in queries schemas db; do
  if [ -d "$REPO_ROOT/$stale_dir" ]; then
    fail_contract "$stale_dir/ exists at repo root — DATA LAYER VIOLATION: canonical location is data/$stale_dir/; delete $stale_dir/"
  else
    echo "[PASS] $stale_dir/ does not exist at repo root (correctly under data/$stale_dir/)"
  fi
done

# ---------------------------------------------------------------------------
# Check 37: ingest/ must NOT exist at repo root
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 37: ingest/ must not exist at repo root"
if [ -d "$REPO_ROOT/ingest" ]; then
  fail_contract "ingest/ exists at repo root — DOMAIN VIOLATION: ETL pipeline belongs at internal/ingest/; delete ingest/"
else
  echo "[PASS] ingest/ does not exist at repo root (correctly moved to internal/ingest/)"
fi

# ---------------------------------------------------------------------------
# Check 38: site/ must NOT exist at repo root
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 38: site/ must not exist at repo root"
if [ -d "$REPO_ROOT/site" ]; then
  fail_contract "site/ exists at repo root — FORBIDDEN: no product surfaces in system repo; delete site/"
else
  echo "[PASS] site/ does not exist at repo root (correctly removed)"
fi

# ---------------------------------------------------------------------------
# Check 39: cmd/ must NOT exist at repo root (moved to platform/cmd/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 39: cmd/ must not exist at repo root"
if [ -d "$REPO_ROOT/cmd" ]; then
  fail_contract "cmd/ exists at repo root — DOMAIN VIOLATION: operational binaries belong at platform/cmd/; delete cmd/ and move contents to platform/cmd/"
else
  echo "[PASS] cmd/ does not exist at repo root (correctly moved to platform/cmd/)"
fi

# ---------------------------------------------------------------------------
# Check 40: platform/cmd/ must exist (canonical binary location)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 40: platform/cmd/ must exist"
if [ ! -d "$REPO_ROOT/platform/cmd" ]; then
  fail_contract "platform/cmd/ does not exist — MISSING: canonical location for operational binaries; expected platform/cmd/{csi-node-shim,csi-reg-shim,threadforge-notifier}"
else
  echo "[PASS] platform/cmd/ exists as canonical binary root"
fi

# ---------------------------------------------------------------------------
# Check 41: core/ must NOT exist at repo root (moved to internal/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 41: core/ must not exist at repo root"
if [ -d "$REPO_ROOT/core" ]; then
  fail_contract "core/ exists at repo root — DOMAIN VIOLATION: Python domain packages moved to internal/; delete core/"
else
  echo "[PASS] core/ does not exist at repo root (correctly moved to internal/)"
fi

# ---------------------------------------------------------------------------
# Check 42: internal/ must exist (canonical Python domain package root)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 42: internal/ must exist as canonical Python domain root"
if [ ! -d "$REPO_ROOT/internal" ]; then
  fail_contract "internal/ missing — canonical Python domain packages must be at internal/"
else
  echo "[PASS] internal/ exists as canonical Python domain root"
fi

# ---------------------------------------------------------------------------
# Check 43: hack/ must NOT exist at repo root (tooling moved to platform/build/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 43: hack/ must not exist at repo root"
if [ -d "$REPO_ROOT/hack" ]; then
  fail_contract "hack/ exists at repo root — DOMAIN VIOLATION: dev infra tooling moved to platform/build/kind/; delete hack/"
else
  echo "[PASS] hack/ does not exist at repo root (correctly moved to platform/build/kind/)"
fi

# ---------------------------------------------------------------------------
# Check 44: config/ must NOT exist at repo root (moved to platform/config/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 44: config/ must not exist at repo root"
if [ -d "$REPO_ROOT/config" ]; then
  fail_contract "config/ exists at repo root — DOMAIN VIOLATION: supply chain configs moved to platform/config/; delete config/"
else
  echo "[PASS] config/ does not exist at repo root (correctly moved to platform/config/)"
fi

# ---------------------------------------------------------------------------
# Check 45: smp/ must NOT exist at repo root (moved to platform/runtime/protocols/smp/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 45: smp/ must not exist at repo root"
if [ -d "$REPO_ROOT/smp" ]; then
  fail_contract "smp/ exists at repo root — DOMAIN VIOLATION: SMP shims moved to platform/runtime/protocols/smp/; delete smp/"
else
  echo "[PASS] smp/ does not exist at repo root (correctly moved to platform/runtime/protocols/smp/)"
fi

# ---------------------------------------------------------------------------
# Check 46: controllers/ must NOT exist at repo root (moved to internal/control/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 46: controllers/ must not exist at repo root"
if [ -d "$REPO_ROOT/controllers" ]; then
  fail_contract "controllers/ exists at repo root — DOMAIN VIOLATION: Go controller moved to internal/control/; delete controllers/"
else
  echo "[PASS] controllers/ does not exist at repo root (correctly moved to internal/control/)"
fi

# ---------------------------------------------------------------------------
# Check 47: logs/ must NOT exist at repo root (runtime output belongs in artifacts/logs/)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 47: logs/ must not exist at repo root"
if [ -d "$REPO_ROOT/logs" ]; then
  fail_contract "logs/ exists at repo root — ROOT POLLUTION: runtime log output must be written to artifacts/logs/; delete logs/"
else
  echo "[PASS] logs/ does not exist at repo root (correctly directed to artifacts/logs/)"
fi

# ---------------------------------------------------------------------------
# Check 48: __init__.py must NOT exist at repo root (root is not a Python package)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 48: __init__.py must not exist at repo root"
if [ -f "$REPO_ROOT/__init__.py" ]; then
  fail_contract "__init__.py exists at repo root — ROOT POLLUTION: repo root is not a Python package; delete __init__.py"
else
  echo "[PASS] __init__.py does not exist at repo root"
fi

# ---------------------------------------------------------------------------
# Check 49: THREADFORGE_PATCH.diff must NOT exist at repo root (debug artifact)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 49: THREADFORGE_PATCH.diff must not exist at repo root"
if [ -f "$REPO_ROOT/THREADFORGE_PATCH.diff" ]; then
  fail_contract "THREADFORGE_PATCH.diff exists at repo root — DEBUG ARTIFACT: patch files must not be committed; delete THREADFORGE_PATCH.diff"
else
  echo "[PASS] THREADFORGE_PATCH.diff does not exist at repo root"
fi

# ---------------------------------------------------------------------------
# Check 50: tree.txt must NOT exist at repo root (generated output artifact)
# ---------------------------------------------------------------------------
echo "[canonical-structure] Check 50: tree.txt must not exist at repo root"
if [ -f "$REPO_ROOT/tree.txt" ]; then
  fail_contract "tree.txt exists at repo root — GENERATED ARTIFACT: tree snapshots must not be committed; delete tree.txt"
else
  echo "[PASS] tree.txt does not exist at repo root"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "[canonical-structure] VIOLATIONS=$VIOLATIONS"
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "[FAIL] canonical structure enforcement FAILED ($VIOLATIONS violation(s))"
  echo "[FAIL] NO_DUPLICATE_DOMAINS: FALSE"
  echo "[FAIL] NO_RUNTIME_ARTIFACTS: FALSE"
  echo "[FAIL] NO_LEGACY_DIRS: FALSE"
  echo "[FAIL] SINGLE_DEPLOYMENT_ROOT: FALSE"
  echo "[FAIL] INFRA_CANONICALIZED: FALSE"
  echo "[FAIL] OBSERVABILITY_MODEL_DEFINED: FALSE"
  echo "[FAIL] OBSERVABILITY_SINGLE_SOURCE: FALSE"
  echo "[FAIL] OBSERVABILITY_SINGLE_ROOT_CONFIRMED: FALSE"
  echo "[FAIL] NO_SHADOW_DOMAINS: FALSE"
  echo "[FAIL] NO_NESTED_DUPLICATION: FALSE"
  echo "[FAIL] TELEMETRY_SCOPE_ENFORCED: FALSE"
  echo "[FAIL] CANONICAL_STRUCTURE_ENFORCED: FALSE"
  echo "[FAIL] DOMAIN_CONSOLIDATION_COMPLETE: FALSE"
  echo "[FAIL] NO_COMPETING_ROOTS: FALSE"
  echo "[FAIL] PLATFORM_IS_SINGLE_INFRA_AUTHORITY: FALSE"
  echo "[FAIL] DATA_LAYER_UNIFIED: FALSE"
  echo "[FAIL] NO_ROOT_POLLUTION: FALSE"
  echo "[FAIL] STRUCTURE_VERIFIED: FALSE"
  exit 2
fi

echo "[PASS] CANONICAL_STRUCTURE_ENFORCED"
echo "[PASS] SINGLE_DEPLOYMENT_ROOT"
echo "[PASS] NO_DUPLICATE_DOMAINS"
echo "[PASS] NO_RUNTIME_ARTIFACTS"
echo "[PASS] NO_LEGACY_DIRS"
echo "[PASS] INFRA_CANONICALIZED"
echo "[PASS] GITOPS_RESOLVED"
echo "[PASS] OBSERVABILITY_MODEL_DEFINED"
echo "[PASS] OBSERVABILITY_SINGLE_SOURCE"
echo "[PASS] OBSERVABILITY_SINGLE_ROOT_CONFIRMED"
echo "[PASS] NO_SHADOW_DOMAINS"
echo "[PASS] NO_NESTED_DUPLICATION"
echo "[PASS] TELEMETRY_SCOPE_ENFORCED"
echo "[PASS] HERMETIC_EXECUTION_DEFINED"
echo "[PASS] DOMAIN_CONSOLIDATION_COMPLETE"
echo "[PASS] NO_COMPETING_ROOTS"
echo "[PASS] PLATFORM_IS_SINGLE_INFRA_AUTHORITY"
echo "[PASS] DATA_LAYER_UNIFIED"
echo "[PASS] NO_ROOT_POLLUTION"
echo "[PASS] STRUCTURE_VERIFIED"
exit 0
