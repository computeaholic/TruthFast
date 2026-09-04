#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="${THREADFORGE_AUDIT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
AUDIT_ROOT="${THREADFORGE_AUDIT_ROOT:-$REPO_ROOT/artifacts/audit}"
MERMAID_ROOT="${THREADFORGE_MERMAID_ROOT:-$REPO_ROOT/artifacts/mermaid}"
source "$REPO_ROOT/scripts/lib/report_path_policy.sh"

OUT_DIR="$(tf_resolve_report_dir_or_fail "$REPO_ROOT" "${THREADFORGE_AUDIT_OUT_DIR:-$AUDIT_ROOT/$RUN_ID}" "THREADFORGE_AUDIT_OUT_DIR")"
MERMAID_DIR="$(tf_resolve_report_dir_or_fail "$REPO_ROOT" "${THREADFORGE_MERMAID_OUT_DIR:-$MERMAID_ROOT/$RUN_ID}" "THREADFORGE_MERMAID_OUT_DIR")"

if [[ -x "$REPO_ROOT/.venv/bin/python" ]]; then
  PYTHON="$REPO_ROOT/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON="$(command -v python3)"
else
  echo "python3 is required for audit report generation" >&2
  exit 2
fi

export REPO_ROOT OUT_DIR PYTHON RUN_ID AUDIT_ROOT MERMAID_ROOT MERMAID_DIR

source "$REPO_ROOT/scripts/audit/lib/utils.sh"
source "$REPO_ROOT/scripts/audit/lib/identity.sh"
source "$REPO_ROOT/scripts/audit/lib/istio.sh"
source "$REPO_ROOT/scripts/audit/lib/observability.sh"
source "$REPO_ROOT/scripts/audit/lib/runtime.sh"
source "$REPO_ROOT/scripts/audit/lib/repo_authority.sh"
source "$REPO_ROOT/scripts/audit/lib/forgesec.sh"

collect_metadata() {
  date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT_DIR/meta/timestamp.txt"
  uname -a > "$OUT_DIR/meta/system_info.txt" 2>/dev/null || true

  if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$REPO_ROOT" rev-parse HEAD > "$OUT_DIR/meta/git_sha.txt" 2>/dev/null || true
    git -C "$REPO_ROOT" branch --show-current > "$OUT_DIR/meta/git_branch.txt" 2>/dev/null || true
  else
    echo "unknown" > "$OUT_DIR/meta/git_sha.txt"
    echo "unknown" > "$OUT_DIR/meta/git_branch.txt"
  fi

  if command -v kubectl >/dev/null 2>&1 && kubectl get ns >/dev/null 2>&1; then
    kubectl version --client > "$OUT_DIR/meta/kubectl_version.txt" 2>/dev/null || true
    kubectl config current-context > "$OUT_DIR/meta/cluster_context.txt" 2>/dev/null || true
  else
    echo "unavailable" > "$OUT_DIR/meta/cluster_context.txt"
  fi
}

generate_mermaids() {
  section "Mermaid Generation"
  mkdir -p "$MERMAID_DIR"
  if "$PYTHON" "$REPO_ROOT/scripts/audit/generate_mermaids.py" "$OUT_DIR" "$MERMAID_DIR" > "$OUT_DIR/raw/mermaid_generation.log" 2>&1; then
    printf '%s\n' "$MERMAID_DIR" > "$MERMAID_ROOT/LATEST"
    "$PYTHON" - "$MERMAID_DIR" "$OUT_DIR/meta/mermaid_manifest.json" <<'PY'
import json
import sys
from pathlib import Path

mermaid_dir = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
manifest = {
    "root": str(mermaid_dir),
    "files": sorted(path.name for path in mermaid_dir.glob("*.mmd")),
}
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
    ok "Generated Mermaid diagrams in $MERMAID_DIR"
    record_check "mermaid" "Mermaid Generation" "PASS" "generated diagrams"
    return 0
  fi

  record_check "mermaid" "Mermaid Generation" "FAIL" "generator returned non-zero"
  echo "Mermaid generation failed; see $OUT_DIR/raw/mermaid_generation.log" >&2
  return 1
}

generate_sbom() {
  section "SBOM Generation"
  if command -v syft >/dev/null 2>&1; then
    if syft "dir:$REPO_ROOT" -o cyclonedx-json > "$OUT_DIR/sbom/sbom.cdx.json" 2> "$OUT_DIR/raw/sbom.log"; then
      ok "Generated SBOM with syft"
      record_check "sbom" "SBOM Generation" "PASS" "syft cyclonedx-json"
      return
    fi
    printf 'syft failed, falling back to repository generator\n' >> "$OUT_DIR/raw/sbom.log"
  fi

  if "$PYTHON" "$REPO_ROOT/scripts/audit/generate_sbom.py" "$REPO_ROOT" "$OUT_DIR/sbom/sbom.cdx.json" >> "$OUT_DIR/raw/sbom.log" 2>&1; then
    ok "Generated SBOM with repository generator"
    record_check "sbom" "SBOM Generation" "PASS" "threadforge cyclonedx generator"
    return
  fi

  record_check "sbom" "SBOM Generation" "FAIL" "generator returned non-zero"
  echo "SBOM generation failed; see $OUT_DIR/raw/sbom.log" >&2
  return 1
}

write_output_authority_matrix() {
  cat > "$OUT_DIR/meta/output_authority_matrix.json" <<EOF
[
  {
    "target": "make audit",
    "script": "scripts/audit/run_full_audit.sh",
    "output_path": "$OUT_DIR",
    "consumer": "audit_report.json, artifacts/audit/LATEST, make mermaids"
  },
  {
    "target": "make mermaids",
    "script": "scripts/generate_mermaids.py",
    "output_path": "$MERMAID_DIR",
    "consumer": "scripts/debug/view_diagrams.sh"
  },
  {
    "target": "make forgesec",
    "script": "scripts/make/forgesec.mk",
    "output_path": "$REPO_ROOT/artifacts/forgesec/<run>",
    "consumer": "make security-gate"
  },
  {
    "target": "scripts/debug/dump_runtime_images.sh",
    "script": "scripts/debug/dump_runtime_images.sh",
    "output_path": "$REPO_ROOT/artifacts/runtime/runtime_images.txt",
    "consumer": "scripts/debug/classify_drift.sh, scripts/debug/diff_cluster_images.sh"
  }
]
EOF
}

write_latest_pointer() {
  mkdir -p "$AUDIT_ROOT" "$MERMAID_ROOT"
  printf '%s\n' "$OUT_DIR" > "$AUDIT_ROOT/LATEST"
}

write_reports() {
  section "Report Generation"
  "$PYTHON" - "$OUT_DIR" <<'PY'
import json
import sys
from pathlib import Path

out_dir = Path(sys.argv[1])
meta = out_dir / "meta"
checks_tsv = meta / "checks.tsv"
checks = []
if checks_tsv.exists():
    for line in checks_tsv.read_text().splitlines():
        if not line.strip():
            continue
        check_id, name, status, summary = line.split("\t", 3)
        checks.append({
            "id": check_id,
            "name": name,
            "status": status,
            "summary": summary,
        })

def read_text(path: Path, default: str = "unknown") -> str:
    return path.read_text().strip() if path.exists() else default

git_sha = read_text(meta / "git_sha.txt")
git_branch = read_text(meta / "git_branch.txt")
timestamp = read_text(meta / "timestamp.txt")
cluster_context = read_text(meta / "cluster_context.txt", "unavailable")

mermaid_manifest_path = out_dir / "meta" / "mermaid_manifest.json"
mermaid_manifest = {"root": "", "files": []}
if mermaid_manifest_path.exists():
  mermaid_manifest = json.loads(mermaid_manifest_path.read_text())
sbom_files = sorted(str(path.relative_to(out_dir)) for path in (out_dir / "sbom").glob("*"))
raw_files = sorted(str(path.relative_to(out_dir)) for path in (out_dir / "raw").glob("*"))
matrix_path = out_dir / "meta" / "output_authority_matrix.json"
output_authority = json.loads(matrix_path.read_text()) if matrix_path.exists() else []

status_counts = {
    status: sum(1 for check in checks if check["status"] == status)
    for status in ("PASS", "WARN", "FAIL")
}
overall_status = "FAIL" if status_counts["FAIL"] else ("WARN" if status_counts["WARN"] else "PASS")

report = {
    "schema_version": 1,
    "run_id": out_dir.name,
    "status": overall_status,
    "status_counts": status_counts,
    "timestamp": timestamp,
    "git_sha": git_sha,
    "git_branch": git_branch,
    "cluster_context": cluster_context,
  "audit_model": {
    "canonical_entrypoint": "make audit",
    "legacy_k3s_dispatcher_supported": False,
    "forensics_isolated": True,
  },
    "checks": checks,
    "artifacts": {
        "raw": raw_files,
      "mermaid": mermaid_manifest,
        "sbom": sbom_files,
    },
    "output_authority": output_authority,
}
manifest = {
    "schema_version": 1,
    "run_id": out_dir.name,
    "status": overall_status,
    "timestamp": timestamp,
    "git_sha": git_sha,
    "git_branch": git_branch,
    "checks_ran": [check["id"] for check in checks],
    "artifact_roots": {
        "raw": "raw",
        "meta": "meta",
        "sbom": "sbom",
      "mermaid": mermaid_manifest.get("root", ""),
    },
}

(out_dir / "audit_report.json").write_text(json.dumps(report, indent=2) + "\n")
(out_dir / "meta" / "run_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

summary_lines = [
    "# ThreadForge Audit Report",
    "",
    f"Timestamp (UTC): {timestamp}",
    f"Git SHA: {git_sha}",
    f"Git Branch: {git_branch}",
    f"Cluster Context: {cluster_context}",
    f"Overall Status: {overall_status}",
    "",
    "## Checks",
]
for check in checks:
    summary_lines.append(f"- {check['name']}: {check['status']} ({check['summary']})")
summary_lines.extend([
    "",
  "## Audit Model",
  "- canonical_entrypoint: make audit",
  "- legacy_k3s_dispatcher_supported: false",
  "- forensics_isolated: true",
  "",
    "## Output Authority",
    f"- audit_root: {out_dir}",
    f"- mermaid_root: {mermaid_manifest.get('root', 'none')}",
    "",
    "## Artifacts",
    f"- mermaid: {', '.join(mermaid_manifest.get('files', [])) if mermaid_manifest.get('files') else 'none'}",
    f"- sbom: {', '.join(sbom_files) if sbom_files else 'none'}",
    f"- raw: {len(raw_files)} files",
])
(out_dir / "audit_report.md").write_text("\n".join(summary_lines) + "\n")
(out_dir / "SUMMARY.txt").write_text(
    "THREADFORGE AUDIT SUMMARY\n"
    f"timestamp={timestamp}\n"
    f"git_sha={git_sha}\n"
    f"cluster_context={cluster_context}\n"
    f"checks={len(checks)}\n"
    f"status={overall_status}\n"
    f"mermaid_root={mermaid_manifest.get('root', '')}\n"
)
PY
  ok "Generated audit_report.json, audit_report.md, SUMMARY.txt, and meta/run_manifest.json"
}

main() {
  ensure_audit_dirs
  mkdir -p "$AUDIT_ROOT" "$MERMAID_ROOT"
  banner "THREADFORGE CANONICAL AUDIT"
  echo "repo_root=$REPO_ROOT"
  echo "out_dir=$OUT_DIR"
  echo "mermaid_dir=$MERMAID_DIR"
  echo "python=$PYTHON"

  run_phase "identity" "Identity Canon" identity_audit
  run_phase "istio" "Istio Enforcement" istio_audit
  run_phase "observability" "Observability Wiring" observability_audit
  run_phase "runtime" "Runtime Discipline" runtime_audit
  run_phase "repo_authority" "Repository Output Authority" repo_authority_audit
  run_phase "forgesec" "ForgeSec Wiring" forgesec_audit

  generate_mermaids || true
  generate_sbom || true
  collect_metadata
  write_output_authority_matrix
  write_latest_pointer
  write_reports

  banner "AUDIT COMPLETE"
  echo "artifacts=$OUT_DIR"
  if grep -q $'\tFAIL\t' "$OUT_DIR/meta/checks.tsv"; then
    echo "AUDIT_STATUS=FAIL"
    return 2
  fi
  if grep -q $'\tWARN\t' "$OUT_DIR/meta/checks.tsv"; then
    echo "AUDIT_STATUS=WARN"
  else
    echo "AUDIT_STATUS=PASS"
  fi
}

main "$@"
