#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# verify_repo_structure.sh — ThreadForge repository structure validator
#
# Checks that the repository conforms to the agreed directory layout:
#   - No bare *.sh scripts at repo root
#   - No artifact spill (artifacts_run* / test_aas_*) at root
#   - Required top-level dirs exist (internal/, scripts/verify/, scripts/tests/, etc.)
#   - scripts/ subdirectory conventions
#
# ENFORCE mode:
#   ENFORCE_STRUCTURE=true  → exits 1 on any violation (blocks CI, default)
#   ENFORCE_STRUCTURE=false → emits [FAIL] lines but does not gate
#
# Override: ENFORCE_STRUCTURE=false make verify
# =============================================================================

ENFORCE="${ENFORCE_STRUCTURE:-true}"
VIOLATIONS=0
FAIL_LIST=()

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo ".")}"

warn_or_fail() {
  local msg="$1"
  echo "[FAIL] $msg"
  VIOLATIONS=$(( VIOLATIONS + 1 ))
  FAIL_LIST+=("$msg")
}

echo "[repo-structure] ENFORCE=${ENFORCE}  root=$REPO_ROOT"

# ---------------------------------------------------------------------------
# Check 1: No bare *.sh files at repo root
# ---------------------------------------------------------------------------
echo "[repo-structure] Check 1: no bare shell scripts at repo root"
mapfile -t ROOT_SH < <(find "$REPO_ROOT" -maxdepth 1 -name "*.sh" -type f 2>/dev/null || true)
if [ "${#ROOT_SH[@]}" -gt 0 ]; then
  for sh in "${ROOT_SH[@]}"; do
    warn_or_fail "bare shell script at root: $(basename "$sh") — move to scripts/"
  done
else
  echo "[PASS] no bare shell scripts at root"
fi

# ---------------------------------------------------------------------------
# Check 2: No artifact spill at root (artifacts_run*)
# NOTE: Top-level `test_aas*` directories are forbidden — tests must use
#       `artifacts/` or temporary directories. Any `test_aas*` at repo root
#       is considered an artifact spill and will fail CI.
# ---------------------------------------------------------------------------
echo "[repo-structure] Check 2: no artifact spill at root"
mapfile -t SPILL < <(find "$REPO_ROOT" -maxdepth 1 -type d \
  \( -name "artifacts_run*" -o -name "artifacts_run*_normalized" -o -name "test_aas*" \) 2>/dev/null || true)
if [ "${#SPILL[@]}" -gt 0 ]; then
  for d in "${SPILL[@]}"; do
    warn_or_fail "artifact spill at root: $(basename "$d") — FORBIDDEN: artifacts_run*/test_aas* dirs must not exist at repo root (use tmp_path in tests; AAS outputs go to artifacts/aas/)"
  done
else
  echo "[PASS] no artifact spill at root"
fi

# ---------------------------------------------------------------------------
# Check 2b: No forbidden test_aas* dirs at repo root
# ---------------------------------------------------------------------------
mapfile -t TEST_AAS < <(find "$REPO_ROOT" -maxdepth 1 -type d -name "test_aas*" 2>/dev/null || true)
if [ "${#TEST_AAS[@]}" -gt 0 ]; then
  for d in "${TEST_AAS[@]}"; do
    warn_or_fail "forbidden top-level test_aas directory at root: $(basename "$d") — update tests to use artifacts/ or tmp dirs"
  done
else
  echo "[PASS] no test_aas* dirs at root"
fi

# ---------------------------------------------------------------------------
# Check 2b: scripts/tests/ must not exist (contents live in scripts/proof/)
# ---------------------------------------------------------------------------
echo "[repo-structure] Check 2b: scripts/tests/ is forbidden (use scripts/proof/)"
if [ -d "$REPO_ROOT/scripts/tests" ]; then
  warn_or_fail "scripts/tests/ directory exists — FORBIDDEN: move test scripts to scripts/proof/ and delete scripts/tests/"
else
  echo "[PASS] scripts/tests/ does not exist"
fi

# ---------------------------------------------------------------------------
# Check 3: Required top-level directories exist
# ---------------------------------------------------------------------------
echo "[repo-structure] Check 3: required directories exist"
REQUIRED_DIRS=(
  "scripts"
  "scripts/verify"
  "scripts/proof"
  "scripts/install"
  "scripts/make"
  ".github/workflows"
  "docs"
)
for dir in "${REQUIRED_DIRS[@]}"; do
  full="$REPO_ROOT/$dir"
  if [ ! -d "$full" ]; then
    warn_or_fail "required directory missing: $dir"
  else
    echo "[PASS] exists: $dir"
  fi
done

# ---------------------------------------------------------------------------
# Check 4: Core domain directories exist (post-migration)
# ---------------------------------------------------------------------------
echo "[repo-structure] Check 4: core domain layout"
CORE_DIRS=(
  "internal/identity"
  "internal/db"
  "internal/schemas"
)
for dir in "${CORE_DIRS[@]}"; do
  full="$REPO_ROOT/$dir"
  if [ ! -d "$full" ]; then
    warn_or_fail "core domain directory missing: $dir (run architecture migration)"
  else
    echo "[PASS] exists: $dir"
  fi
done

# ---------------------------------------------------------------------------
# Check 5: No __pycache__ directories at depth ≤ 2 (root noise)
# ---------------------------------------------------------------------------
echo "[repo-structure] Check 5: no __pycache__ at root depth"
find "$REPO_ROOT" -maxdepth 2 -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
mapfile -t PYCACHE < <(find "$REPO_ROOT" -maxdepth 2 -name "__pycache__" -type d 2>/dev/null || true)
if [ "${#PYCACHE[@]}" -gt 0 ]; then
  warn_or_fail "__pycache__ dirs at root depth (${#PYCACHE[@]} found) — add to .gitignore and delete"
else
  echo "[PASS] no __pycache__ at root depth"
fi

# ---------------------------------------------------------------------------
# Check 6: Proof scripts exist (minimum viable proof chain)
# ---------------------------------------------------------------------------
echo "[repo-structure] Check 6: proof chain scripts present"
PROOF_SCRIPTS=(
  "scripts/prove_system.sh"
  "scripts/verify/registry_health.sh"
  "scripts/verify/enforce_image_digests.sh"
  "scripts/verify/runtime_invariants.sh"
  "scripts/verify/test_containment_flows.sh"
  "scripts/verify/verify_no_external_runtime_images.sh"
  "scripts/verify/verify_trace_log_correlation.sh"
  "scripts/proof/test_allow.sh"
  "scripts/proof/test_deny.sh"
  "scripts/proof/test_egress.sh"
)
for script in "${PROOF_SCRIPTS[@]}"; do
  full="$REPO_ROOT/$script"
  if [ ! -f "$full" ]; then
    warn_or_fail "proof script missing: $script"
  elif [ ! -x "$full" ]; then
    warn_or_fail "proof script not executable: $script (run chmod +x)"
  else
    echo "[PASS] present + executable: $script"
  fi
done

# ---------------------------------------------------------------------------
# Check 7: No unexpected files at repo root (noise/artifact detection)
# Allowlist: Makefile, *.toml, *.yml, *.yaml, *.md, *.json, requirements.txt,
#            .git*, __init__.py, *.diff, *.cfg, *.ini
# Everything else (random_file.txt, *.log, etc.) is a violation.
# ---------------------------------------------------------------------------
echo "[repo-structure] Check 7: no unexpected files at repo root"
mapfile -t ROOT_UNEXPECTED < <(find "$REPO_ROOT" -maxdepth 1 -type f \
  ! -name "Makefile" \
  ! -name "*.md" \
  ! -name "*.toml" \
  ! -name "*.yml" \
  ! -name "*.yaml" \
  ! -name "*.json" \
  ! -name "*.cfg" \
  ! -name "*.ini" \
  ! -name "*.diff" \
  ! -name "*.py" \
  ! -name "*.lock" \
  ! -name "requirements.txt" \
  ! -name ".gitignore" \
  ! -name ".gitattributes" \
  ! -name ".dockerignore" \
  ! -name ".editorconfig" \
  ! -name ".env" \
  ! -name ".env.*" \
  ! -name ".sqlfluff" \
  ! -name ".flake8" \
  ! -name ".pylintrc" \
  ! -name ".pre-commit-config.yaml" \
  2>/dev/null | sort || true)
if [ "${#ROOT_UNEXPECTED[@]}" -gt 0 ]; then
  for f in "${ROOT_UNEXPECTED[@]}"; do
    warn_or_fail "unexpected file at repo root: $(basename "$f") — move or delete"
  done
else
  echo "[PASS] no unexpected files at repo root"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "[repo-structure] Results: VIOLATIONS=$VIOLATIONS ENFORCE=$ENFORCE"
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "[FAIL] repository structure validation FAILED:"
  for f in "${FAIL_LIST[@]}"; do echo "  [FAIL] $f"; done
  if [ "$ENFORCE" = "true" ]; then
    exit 2
  fi
fi

echo "[PASS] repository structure verified"
exit 0
