#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TRANSIENT_TTL_DAYS="${TRANSIENT_TTL_DAYS:-14}"

fail() {
  echo "[FAIL] $*"
  exit 2
}

pass() {
  echo "[PASS] $*"
}

search_regex() {
  local pattern="$1"
  shift
  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$@"
  else
    grep -R -n -E -- "$pattern" "$@"
  fi
}

reject_pattern_in_files() {
  local pattern="$1"
  shift
  if search_regex "$pattern" "$@" >/dev/null 2>&1; then
    echo "[FAIL] forbidden pattern detected: $pattern"
    search_regex "$pattern" "$@" || true
    exit 2
  fi
}

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

# Root governance: keep the root small and explicitly enumerate authority docs.
ROOT_ALLOWED_FILES=(
  "AGENTS.md"
  ".dockerignore"
  ".editorconfig"
  ".gitignore"
  ".pre-commit-config.yaml"
  ".ruff.toml"
  ".sqlfluff"
  "LICENSE"
  "Makefile"
  "THIRD_PARTY_NOTICES.md"
  "mkdocs.yml"
  "pyproject.toml"
  "pyrightconfig.json"
  "README.md"
  "requirements.txt"
)

ROOT_FORBIDDEN_PATTERN='^(FINAL_|CURRENT_|TRACE_|FORENSICS_|REMEDIATION_|ANALYSIS_|EXECUTION_|RECERTIFICATION_|ROOT_CAUSE_)'

DOC_CANONICAL_PATHS=(
  "docs/Agent-Containment.md"
  "docs/index.md"
  "docs/START_HERE.md"
  "docs/architecture/repository-manifest.yaml"
  "docs/architecture/00-ThreadForge-Assurance-Reference-Architecture.md"
  "docs/architecture/01-Constitution.md"
  "docs/architecture/02-Constitutional-Principles.md"
  "docs/architecture/03-Assurance-Capabilities.md"
  "docs/architecture/04-Constitutional-Claims.md"
  "docs/architecture/05-Evidence-Contracts.md"
  "docs/architecture/06-Proof-Architecture.md"
  "docs/architecture/07-Certification-Architecture.md"
  "docs/architecture/08-Provider-Architecture.md"
  "docs/architecture/09-Capability-Bindings.md"
  "docs/architecture/10-Profiles.md"
  "docs/architecture/11-Native-Reference-Implementation.md"
  "docs/architecture/12-BigBang-Profile.md"
  "docs/architecture/ENGINEERING_DOCTRINE.md"
  "docs/CANONICAL/ENGINEERING_LEXICON.md"
  "docs/architecture/14-Governance.md"
  "docs/architecture/15-Migration-Strategy.md"
  "docs/architecture/16-Repository-Information-Model.md"
  "docs/architecture/system-model/project_obligations.json"
  "docs/architecture/system-model/research_doctrine_matrix.json"
  "docs/CANONICAL/README.md"
  "docs/CANONICAL/ARCHITECTURE.md"
  "docs/CANONICAL/AUDIT_MODEL.md"
  "docs/CANONICAL/IDENTITY.md"
  "docs/CANONICAL/OBSERVABILITY.md"
  "docs/CANONICAL/POLICY_ENFORCEMENT.md"
  "docs/CANONICAL/PROOF_CONTRACT.md"
  "docs/CANONICAL/PROOF_MODEL.md"
  "docs/CANONICAL/REDTEAM.md"
  "docs/CANONICAL/RUNBOOK.md"
  "docs/CANONICAL/SECURITY_MODEL.md"
  "docs/CANONICAL/SUPPLY_CHAIN.md"
  "docs/CANONICAL/TRUST_MODEL.md"
  "docs/operations/README.md"
  "docs/operations/OBSERVABILITY.md"
  "docs/governance/README.md"
  "docs/governance/REGISTRY_DIAGNOSTIC_ISOLATION_PLAN.md"
  "docs/governance/REGISTRY_GOVERNANCE_ENFORCEMENT_PLAN.md"
  "docs/governance/REGISTRY_PROMOTION_BOUNDARY.md"
  "docs/governance/REGISTRY_RETENTION_POLICY.md"
  "docs/lifecycle/README.md"
  "docs/lifecycle/REGISTRY_PURGE_EXECUTION_MATRIX.md"
  "docs/lifecycle/REGISTRY_RETENTION_CLASSIFICATION.md"
  "docs/policies/README.md"
  "docs/releases/README.md"
  "docs/releases/CERTIFICATION_BASELINE.md"
  "docs/policies/policy-registry.yaml"
)

is_root_allowed_file() {
  local candidate="$1"
  local allowed
  for allowed in "${ROOT_ALLOWED_FILES[@]}"; do
    [[ "$candidate" == "$allowed" ]] && return 0
  done
  return 1
}

# CI workflows must not call canonical runtime scripts directly.
if [[ -d "$WORKFLOW_DIR" ]]; then
  reject_pattern_in_files '(run:[[:space:]]*.*(bash|sh)[[:space:]]+scripts/(infra/bootstrap|prove_system|forgesec/run_k8s_suite)\.sh|^[[:space:]]*(bash|sh)[[:space:]]+scripts/(infra/bootstrap|prove_system|forgesec/run_k8s_suite)\.sh)' "$WORKFLOW_DIR"
  reject_pattern_in_files 'THREADFORGE_HOST_TRUST_MUTATION=allowed' "$WORKFLOW_DIR"
fi

# Root artifact hygiene guard.
mapfile -t ROOT_FILES < <(find "$REPO_ROOT" -maxdepth 1 -type f ! -name '.git' -printf '%f\n' | sort)
ROOT_VIOLATIONS=0
for root_file in "${ROOT_FILES[@]}"; do
  if ! is_root_allowed_file "$root_file"; then
    echo "[FAIL] root artifact not in allowlist: $root_file"
    ROOT_VIOLATIONS=1
  fi
done

if [[ $ROOT_VIOLATIONS -ne 0 ]]; then
  fail "root artifact governance violated: non-canonical root files detected"
fi

if find "$REPO_ROOT" -maxdepth 1 -type f -name '*.md' \
  ! -name 'README.md' \
  ! -name 'THIRD_PARTY_NOTICES.md' \
  ! -name 'AGENTS.md' | grep -q .; then
  fail "root markdown is restricted to the curated authority set"
fi

if find "$REPO_ROOT" -maxdepth 1 -type f ! -name '.git' -printf '%f\n' | grep -n -E "$ROOT_FORBIDDEN_PATTERN" >/dev/null 2>&1; then
  echo "[FAIL] forbidden root naming pattern detected"
  find "$REPO_ROOT" -maxdepth 1 -type f ! -name '.git' -printf '%f\n' | grep -n -E "$ROOT_FORBIDDEN_PATTERN" || true
  exit 2
fi

# Canonical docs only: verify the active navigation surface rather than every
# historical markdown artifact retained under docs/.
DOC_DRIFT=0
for canonical_path in "${DOC_CANONICAL_PATHS[@]}"; do
  [[ -f "$REPO_ROOT/$canonical_path" ]] || {
    echo "[FAIL] missing canonical document: $canonical_path"
    DOC_DRIFT=1
  }
done

if [[ $DOC_DRIFT -ne 0 ]]; then
  fail "canonical documentation boundary drift detected"
fi

ACTIVE_NAV_FILES=(
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/mkdocs.yml"
  "$REPO_ROOT/docs/index.md"
  "$REPO_ROOT/docs/START_HERE.md"
)

reject_pattern_in_files 'docs/(onboarding|security|adr)/' "${ACTIVE_NAV_FILES[@]}"
reject_pattern_in_files 'docs/architecture/(ARCHITECTURE|HOW_IT_WORKS|IDENTITY|TRUST_MODEL|PROOF_MODEL)\.md' "${ACTIVE_NAV_FILES[@]}"
reject_pattern_in_files 'docs/operations/CANONICAL_DOC_ENFORCEMENT\.md' "${ACTIVE_NAV_FILES[@]}"
reject_pattern_in_files '(^|[^[:alnum:]_-])mesh-unlock([^[:alnum:]_-]|$)' "$REPO_ROOT/Makefile"

HIERARCHY_FILES=(
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/docs/index.md"
  "$REPO_ROOT/docs/START_HERE.md"
  "$REPO_ROOT/docs/Agent-Containment.md"
  "$REPO_ROOT/docs/CANONICAL/README.md"
  "$REPO_ROOT/docs/architecture/_manifest.md"
  "$REPO_ROOT/mkdocs.yml"
)

require_file_fragment() {
  local file="$1"
  local fragment="$2"
  if ! grep -F -q -- "$fragment" "$file"; then
    echo "[FAIL] missing required hierarchy fragment in ${file#$REPO_ROOT/}: $fragment"
    return 1
  fi
}

for hierarchy_file in "${HIERARCHY_FILES[@]}"; do
  [[ -f "$hierarchy_file" ]] || fail "missing hierarchy file: ${hierarchy_file#$REPO_ROOT/}"
done

require_file_fragment "$REPO_ROOT/README.md" "docs/Agent-Containment.md"
require_file_fragment "$REPO_ROOT/README.md" "docs/index.md"
require_file_fragment "$REPO_ROOT/README.md" "docs/architecture/repository-manifest.yaml"
require_file_fragment "$REPO_ROOT/docs/Agent-Containment.md" "precise contracts live in the canonical documents under \`docs/architecture/*\` and \`docs/CANONICAL/*\`"
require_file_fragment "$REPO_ROOT/docs/index.md" "TruthFast documentation hierarchy"
require_file_fragment "$REPO_ROOT/docs/index.md" "docs/Agent-Containment.md"
require_file_fragment "$REPO_ROOT/docs/index.md" "docs/architecture/"
require_file_fragment "$REPO_ROOT/docs/index.md" "docs/CANONICAL/"
require_file_fragment "$REPO_ROOT/docs/CANONICAL/README.md" "The canonical docs own the precise contracts"
require_file_fragment "$REPO_ROOT/docs/architecture/_manifest.md" "Repository information model"
require_file_fragment "$REPO_ROOT/docs/architecture/_manifest.md" "repository-manifest.yaml"
require_file_fragment "$REPO_ROOT/mkdocs.yml" "Constitutional Assurance"
require_file_fragment "$REPO_ROOT/mkdocs.yml" "Architecture:"
require_file_fragment "$REPO_ROOT/mkdocs.yml" "Canonical:"
require_file_fragment "$REPO_ROOT/mkdocs.yml" "Operations:"
require_file_fragment "$REPO_ROOT/mkdocs.yml" "Governance:"
require_file_fragment "$REPO_ROOT/mkdocs.yml" "Lifecycle:"
require_file_fragment "$REPO_ROOT/mkdocs.yml" "Policies:"
require_file_fragment "$REPO_ROOT/mkdocs.yml" "Releases:"

# Make surface governance: every canonical fragment under scripts/make/ must be
# explicitly included by the root Makefile, and every include must resolve.
mapfile -t MAKE_FRAGMENT_FILES < <(find "$REPO_ROOT/scripts/make" -type f -name '*.mk' -print | sort)
mapfile -t MAKE_INCLUDE_PATHS < <(
  grep -E '^include[[:space:]]+scripts/make/' "$REPO_ROOT/Makefile" \
    | awk '{print $2}' \
    | sort -u
)

MAKE_FRAGMENT_DRIFT=0
for fragment in "${MAKE_FRAGMENT_FILES[@]}"; do
  rel="${fragment#$REPO_ROOT/}"
  if ! grep -Fxq "include $rel" "$REPO_ROOT/Makefile"; then
    echo "[FAIL] make fragment not included by root Makefile: $rel"
    MAKE_FRAGMENT_DRIFT=1
  fi
done

for include_path in "${MAKE_INCLUDE_PATHS[@]}"; do
  if [[ ! -f "$REPO_ROOT/$include_path" ]]; then
    echo "[FAIL] Makefile includes missing fragment: $include_path"
    MAKE_FRAGMENT_DRIFT=1
  fi
done

if [[ $MAKE_FRAGMENT_DRIFT -ne 0 ]]; then
  fail "scripts/make fragment governance violated"
fi

# Transient artifact policy.
mkdir -p "$REPO_ROOT/artifacts/tmp"

if find "$REPO_ROOT/artifacts/tmp" -type f -mtime "+${TRANSIENT_TTL_DAYS}" | grep -q .; then
  echo "[FAIL] stale transient artifacts exceed TTL=${TRANSIENT_TTL_DAYS}d"
  find "$REPO_ROOT/artifacts/tmp" -type f -mtime "+${TRANSIENT_TTL_DAYS}" -print
  exit 2
fi

# Historical reports remain allowed if they retain a landing page and stay out of
# the active documentation graph.
[[ -f "$REPO_ROOT/reports/README.md" ]] || fail "reports/ directory must retain a landing page"

pass "repository topology and CI/runtime separation guards are enforced"
