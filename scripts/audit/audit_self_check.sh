#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

required_files=(
  "scripts/audit/run_full_audit.sh"
  "scripts/audit/generate_mermaids.py"
  "scripts/audit/generate_sbom.py"
  "scripts/audit/value_plane_audit.sh"
  "scripts/audit/lib/utils.sh"
  "scripts/audit/lib/identity.sh"
  "scripts/audit/lib/istio.sh"
  "scripts/audit/lib/observability.sh"
  "scripts/audit/lib/runtime.sh"
  "scripts/audit/lib/repo_authority.sh"
  "scripts/audit/lib/forgesec.sh"
  "scripts/forensics/filesystem_snapshot.sh"
  "scripts/verify/registry_audit.sh"
  "tools/dev/containment_audit.py"
)

required_targets=(
  "audit"
  "audit-check"
  "forensics-snapshot"
  "containment-audit"
  "registry-audit"
  "value-plane-audit"
  "ci-audit"
)

cd "$REPO_ROOT"

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR missing file: $file" >&2
    exit 2
  fi
done

for file in "${required_files[@]}"; do
  if [[ "$file" == *.sh || "$file" == scripts/audit/*.py ]]; then
    if [[ ! -x "$file" ]]; then
      echo "ERROR non-executable file: $file" >&2
      exit 2
    fi
  fi
done

for target in "${required_targets[@]}"; do
  if ! make -n "$target" >/dev/null; then
    echo "ERROR unresolved make target: $target" >&2
    exit 2
  fi
done

if [[ ! -f "scripts/audit/run_full_audit.sh" ]]; then
  echo "ERROR canonical entrypoint missing: scripts/audit/run_full_audit.sh" >&2
  exit 2
fi

mapfile -t outside_audit_scripts < <(find scripts -type f -name "*audit*.sh" | grep -v '^scripts/audit/' || true)
if [[ "${#outside_audit_scripts[@]}" -gt 0 ]]; then
  echo "WARN audit-like scripts outside scripts/audit detected:" >&2
  for path in "${outside_audit_scripts[@]}"; do
    echo "WARN  - ${path}" >&2
  done
fi

if awk '
  /^audit[^:]*:/ { in_audit=1; next }
  /^[^ \t].*:/ { in_audit=0 }
  in_audit && /filesystem_snapshot\.sh/ { found=1 }
  END { exit found ? 0 : 2 }
' Makefile; then
  echo "ERROR forensics snapshot appears inside audit target recipes" >&2
  exit 2
fi

if grep -nE '^audit-(k3s|experimental)-' Makefile >/dev/null 2>&1; then
  echo "ERROR legacy or mutating K3s audit targets remain exposed in the supported Make surface" >&2
  exit 2
fi

if rg -n 'audit_output(/|\b)' scripts/audit scripts/generate_mermaids.py scripts/debug/view_diagrams.sh Makefile \
  -g '!audit_self_check.sh' -g '!repo_authority.sh' >/dev/null 2>&1; then
  echo "ERROR stale audit_output reference detected in audit entrypoints or tests" >&2
  exit 2
fi

if rg -n "ppit_flow|ppit_mint_flow|PPIT Validation|A5_ppit" \
  scripts/audit scripts/generate_mermaids.py scripts/debug/view_diagrams.sh tests/scripts \
  -g '!audit_self_check.sh' >/dev/null 2>&1; then
  echo "ERROR stale PPIT audit or Mermaid reference detected" >&2
  exit 2
fi

echo "AUDIT_SELF_CHECK=PASS"
