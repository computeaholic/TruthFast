#!/usr/bin/env python3
"""Render single-file registry governance visibility summary (observe-only)."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
AUTH_MD = REPO_ROOT / "REGISTRY_AUTHORITY_CLASSIFICATION.md"
PURGE_MD = REPO_ROOT / "docs/lifecycle/REGISTRY_PURGE_EXECUTION_MATRIX.md"
PROV_MD = REPO_ROOT / "reports/registry/REGISTRY_PROVENANCE_GAP_AUDIT.md"
OWNER_JSON = REPO_ROOT / "artifacts/governance/REGISTRY_OWNER_VALIDATION.json"
FLOAT_JSON = REPO_ROOT / "artifacts/registry/REGISTRY_FLOATING_TAG_AUDIT.json"
OUT_MD = REPO_ROOT / "reports/registry/REGISTRY_GOVERNANCE_SUMMARY.md"


def _load_text(path: Path) -> str:
    """Read UTF-8 text from path when it exists; otherwise return empty string."""

    return path.read_text(encoding="utf-8") if path.exists() else ""


def _load_summary_json(path: Path) -> dict[str, object]:
    """Read summary JSON for downstream markdown rendering."""

    if not path.exists():
        return {"summary": {}}
    return json.loads(path.read_text(encoding="utf-8"))


def _count_metrics() -> tuple[Counter[str], Counter[str], Counter[str]]:
    """Collect authority, purge-tier, and provenance counts."""

    auth_states = parse_col(_load_text(AUTH_MD), 2)
    purge_tiers = parse_col(_load_text(PURGE_MD), 3)
    prov_rows = parse_col(_load_text(PROV_MD), 2)
    return Counter(auth_states), Counter(purge_tiers), Counter(prov_rows)


def _summary_value(data: dict[str, object], key: str) -> int:
    """Return integer value from nested summary mapping with safe defaults."""

    summary = data.get("summary", {})
    if not isinstance(summary, dict):
        return 0
    value = summary.get(key, 0)
    return int(value) if isinstance(value, int) else 0


def _authority_lines(auth_counts: Counter[str]) -> list[str]:
    """Render authority state count lines."""

    return [
        "## Authority State Counts",
        f"- REQUIRED_RUNTIME: {auth_counts.get('REQUIRED_RUNTIME', 0)}",
        f"- REQUIRED_BOOTSTRAP: {auth_counts.get('REQUIRED_BOOTSTRAP', 0)}",
        f"- REQUIRED_ROLLBACK: {auth_counts.get('REQUIRED_ROLLBACK', 0)}",
        f"- REQUIRED_DIAGNOSTIC: {auth_counts.get('REQUIRED_DIAGNOSTIC', 0)}",
        f"- OPTIONAL_FEATURE: {auth_counts.get('OPTIONAL_FEATURE', 0)}",
        f"- LEGACY_COMPATIBILITY: {auth_counts.get('LEGACY_COMPATIBILITY', 0)}",
        f"- ORPHANED: {auth_counts.get('ORPHANED', 0)}",
        f"- FORBIDDEN_FUTURE_USE: {auth_counts.get('FORBIDDEN_FUTURE_USE', 0)}",
    ]


def _purge_lines(tier_counts: Counter[str]) -> list[str]:
    """Render purge tier count lines."""

    return [
        "## Purge Tier Counts",
        f"- TIER_0: {tier_counts.get('TIER_0', 0)}",
        f"- TIER_1: {tier_counts.get('TIER_1', 0)}",
        f"- TIER_2: {tier_counts.get('TIER_2', 0)}",
        f"- TIER_3: {tier_counts.get('TIER_3', 0)}",
    ]


def _provenance_lines(prov_counts: Counter[str]) -> list[str]:
    """Render provenance gap count lines."""

    return [
        "## Provenance Gap Counts",
        f"- unknown signature state rows: {prov_counts.get('unknown', 0)}",
        f"- verified(true) rows: {prov_counts.get('verified(true)', 0)}",
    ]


def _floating_lines(floating: dict[str, object]) -> list[str]:
    """Render floating tag summary lines."""

    runtime_risk = _summary_value(floating, "FLOATING_TAG_RUNTIME_RISK")
    diagnostic_only = _summary_value(
        floating,
        "FLOATING_TAG_DIAGNOSTIC_ONLY",
    )
    forbidden = _summary_value(floating, "FLOATING_TAG_FORBIDDEN")
    allowed_exception = _summary_value(
        floating,
        "FLOATING_TAG_ALLOWED_EXCEPTION",
    )

    return [
        "## Floating Tag Counts",
        f"- FLOATING_TAG_RUNTIME_RISK: {runtime_risk}",
        f"- FLOATING_TAG_DIAGNOSTIC_ONLY: {diagnostic_only}",
        f"- FLOATING_TAG_FORBIDDEN: {forbidden}",
        f"- FLOATING_TAG_ALLOWED_EXCEPTION: {allowed_exception}",
    ]


def _owner_lines(owner: dict[str, object]) -> list[str]:
    """Render owner attribution gap lines."""

    owner_unassigned = _summary_value(owner, "OWNER_UNASSIGNED")
    owner_invalid = _summary_value(owner, "OWNER_INVALID")
    owner_meta_incomplete = _summary_value(owner, "OWNER_METADATA_INCOMPLETE")

    return [
        "## Owner Attribution Gaps",
        f"- OWNER_UNASSIGNED: {owner_unassigned}",
        f"- OWNER_INVALID: {owner_invalid}",
        f"- OWNER_METADATA_INCOMPLETE: {owner_meta_incomplete}",
    ]


def _critical_inventory_lines(auth_counts: Counter[str]) -> list[str]:
    """Render critical inventory counts derived from authority states."""

    runtime_count = auth_counts.get("REQUIRED_RUNTIME", 0)
    bootstrap_count = auth_counts.get("REQUIRED_BOOTSTRAP", 0)
    rollback_count = auth_counts.get("REQUIRED_ROLLBACK", 0)
    legacy_count = auth_counts.get("LEGACY_COMPATIBILITY", 0)

    runtime_critical = runtime_count + bootstrap_count
    rollback_lineage = rollback_count + legacy_count

    return [
        "## Critical Inventories",
        f"- runtime-critical inventory (runtime + bootstrap): {runtime_critical}",
        f"- rollback lineage inventory: {rollback_lineage}",
        f"- orphan inventory: {auth_counts.get('ORPHANED', 0)}",
        f"- forbidden lineage inventory: {auth_counts.get('FORBIDDEN_FUTURE_USE', 0)}",
    ]


def _build_lines(
    auth_counts: Counter[str],
    tier_counts: Counter[str],
    prov_counts: Counter[str],
    owner: dict[str, object],
    floating: dict[str, object],
) -> list[str]:
    """Build markdown lines for the consolidated governance summary."""

    lines = [
        "# REGISTRY_GOVERNANCE_SUMMARY",
        "",
        "## Mode",
        "- observe-only",
        "",
    ]
    lines += _authority_lines(auth_counts)
    lines += [""]
    lines += _purge_lines(tier_counts)
    lines += [""]
    lines += _provenance_lines(prov_counts)
    lines += [""]
    lines += _floating_lines(floating)
    lines += [""]
    lines += _owner_lines(owner)
    lines += [""]
    lines += _critical_inventory_lines(auth_counts)
    return lines


def parse_col(md_text: str, col_index: int) -> list[str]:
    """Parse a single table column from markdown rows keyed by canonical image refs."""

    vals: list[str] = []
    for line in md_text.splitlines():
        if not line.startswith("| registry.threadforge.local:30500/"):
            continue
        parts = [p.strip() for p in line.strip().split("|")]
        if len(parts) > col_index:
            vals.append(parts[col_index])
    return vals


def main() -> int:
    """Generate the consolidated operator-facing registry governance summary."""

    auth_counts, tier_counts, prov_counts = _count_metrics()
    owner = _load_summary_json(OWNER_JSON)
    floating = _load_summary_json(FLOAT_JSON)
    lines = _build_lines(auth_counts, tier_counts, prov_counts, owner, floating)

    OUT_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")
    out_file = "reports/registry/REGISTRY_GOVERNANCE_SUMMARY.md"
    print(f"[registry-governance-summary] observe-only: wrote {out_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
