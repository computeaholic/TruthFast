#!/usr/bin/env python3
"""Observe-only validator for registry owner attribution metadata."""

from __future__ import annotations

import json
import importlib.util
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parents[2]


def _load_resolve_report_output_path():
    policy_path = REPO_ROOT / "scripts" / "lib" / "report_path_policy.py"
    spec = importlib.util.spec_from_file_location("report_path_policy", policy_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load report path policy helper: {policy_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.resolve_report_output_path


resolve_report_output_path = _load_resolve_report_output_path()

INPUT_MD = REPO_ROOT / "REGISTRY_AUTHORITY_CLASSIFICATION.md"
OUT_JSON = REPO_ROOT / "artifacts/governance/REGISTRY_OWNER_VALIDATION.json"
OUT_MD = REPO_ROOT / "reports/registry/REGISTRY_OWNER_VALIDATION.md"

VALID_OWNER_DOMAINS = {
    "identity",
    "mesh",
    "policy-security",
    "platform-core",
    "observability",
    "data-plane",
    "threadforge-control",
    "upstream-mirror",
    "diagnostics",
    "unassigned",
}

VALID_PROOF_SENS = {"HIGH", "MEDIUM", "LOW"}
VALID_ROLLBACK = {"required", "not-required"}
CLASS_OWNER_METADATA_INCOMPLETE = "OWNER_METADATA_INCOMPLETE"


@dataclass(frozen=True)
class OwnerRow:
    """Single parsed row from REGISTRY_AUTHORITY_CLASSIFICATION.md."""

    image: str
    state: str
    owner: str
    rollback: str
    proof: str
    justification: str


@dataclass(frozen=True)
class ValidationResult:
    """Ownership validation result for one image."""

    image: str
    state: str
    owner: str
    rollback: str
    proof: str
    classification: str
    reason: str


def _parse_table_rows(md_text: str) -> list[OwnerRow]:
    """Parse authority classification markdown into structured ownership rows."""

    rows: list[OwnerRow] = []
    for line in md_text.splitlines():
        if not line.startswith("| registry.threadforge.local:30500/"):
            continue
        parts = [p.strip() for p in line.strip().split("|")]
        if len(parts) < 8:
            continue
        rows.append(
            OwnerRow(
                image=parts[1],
                state=parts[2],
                owner=parts[3],
                rollback=parts[4],
                proof=parts[5],
                justification=parts[6],
            )
        )
    return sorted(rows, key=lambda r: r.image)


def _validate_rows(rows: Iterable[OwnerRow]) -> list[ValidationResult]:
    """Classify each row as valid, invalid, unassigned, or metadata-incomplete."""

    results: list[ValidationResult] = []
    for row in rows:
        reason_parts: list[str] = []
        if row.owner == "unassigned":
            classification = "OWNER_UNASSIGNED"
            reason_parts.append("owner is unassigned")
        elif row.owner not in VALID_OWNER_DOMAINS:
            classification = "OWNER_INVALID"
            reason_parts.append("owner domain not recognized")
        else:
            missing_meta = row.rollback not in VALID_ROLLBACK or row.proof not in VALID_PROOF_SENS
            if missing_meta:
                classification = CLASS_OWNER_METADATA_INCOMPLETE
                if row.rollback not in VALID_ROLLBACK:
                    reason_parts.append("rollback metadata missing/invalid")
                if row.proof not in VALID_PROOF_SENS:
                    reason_parts.append("proof sensitivity missing/invalid")
            else:
                classification = "OWNER_VALID"
                reason_parts.append("owner and metadata complete")

        results.append(
            ValidationResult(
                image=row.image,
                state=row.state,
                owner=row.owner,
                rollback=row.rollback,
                proof=row.proof,
                classification=classification,
                reason="; ".join(reason_parts),
            )
        )
    return results


def _render_md(
    results: list[ValidationResult],
    summary: dict[str, int],
    skip_reason: str | None,
) -> str:
    """Render observe-only ownership validation markdown report."""

    lines: list[str] = [
        "# REGISTRY_OWNER_VALIDATION",
        "",
        "## Mode",
        "- observe-only",
        "",
    ]
    if skip_reason:
        lines += ["## Skip Classification", f"- {skip_reason}", ""]

    lines += [
        "## Summary",
        "",
        f"- OWNER_UNASSIGNED: {summary.get('OWNER_UNASSIGNED', 0)}",
        f"- OWNER_INVALID: {summary.get('OWNER_INVALID', 0)}",
        f"- OWNER_METADATA_INCOMPLETE: {summary.get('OWNER_METADATA_INCOMPLETE', 0)}",
        f"- OWNER_VALID: {summary.get('OWNER_VALID', 0)}",
        "",
        "## Validation Table",
        "",
        "| image | state | owner | rollback | proof | classification | reason |",
        "|---|---|---|---|---|---|---|",
    ]

    for result in results:
        lines.append(
            f"| {result.image} | {result.state} | {result.owner} | {result.rollback} "
            f"| {result.proof} | {result.classification} | {result.reason} |"
        )

    return "\n".join(lines) + "\n"


def _count_classification(
    results: Iterable[ValidationResult],
    classification: str,
) -> int:
    """Count validation results for a specific classification label."""

    return sum(result.classification == classification for result in results)


def main() -> int:
    """Run observe-only ownership validation and write JSON/Markdown outputs."""

    skip_reason: str | None = None
    if not INPUT_MD.exists():
        rows: list[OwnerRow] = []
        skip_reason = "SKIP_INPUT_MISSING: REGISTRY_AUTHORITY_CLASSIFICATION.md not found"
    else:
        rows = _parse_table_rows(INPUT_MD.read_text(encoding="utf-8"))
        if not rows:
            skip_reason = "SKIP_NO_CLASSIFICATION_ROWS: no authority table rows parsed"

    results = _validate_rows(rows)

    owner_unassigned = _count_classification(results, "OWNER_UNASSIGNED")
    owner_invalid = _count_classification(results, "OWNER_INVALID")
    owner_meta_incomplete = _count_classification(
        results,
        CLASS_OWNER_METADATA_INCOMPLETE,
    )
    owner_valid = _count_classification(results, "OWNER_VALID")

    summary = {
        "OWNER_UNASSIGNED": owner_unassigned,
        "OWNER_INVALID": owner_invalid,
        "OWNER_METADATA_INCOMPLETE": owner_meta_incomplete,
        "OWNER_VALID": owner_valid,
    }

    payload = {
        "mode": "observe-only",
        "input": str(INPUT_MD.relative_to(REPO_ROOT)),
        "skip_reason": skip_reason,
        "summary": summary,
        "results": [r.__dict__ for r in results],
    }
    out_json_path = resolve_report_output_path(OUT_JSON, repo_root=REPO_ROOT)
    out_md_path = resolve_report_output_path(OUT_MD, repo_root=REPO_ROOT)
    out_json_path.parent.mkdir(parents=True, exist_ok=True)
    out_md_path.parent.mkdir(parents=True, exist_ok=True)
    out_json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    out_md_path.write_text(_render_md(results, summary, skip_reason), encoding="utf-8")

    output_json = "artifacts/governance/REGISTRY_OWNER_VALIDATION.json"
    output_md = "reports/registry/REGISTRY_OWNER_VALIDATION.md"
    written_files = f"{output_json} and {output_md}"
    print(f"[registry-ownership] observe-only: wrote {written_files}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
