#!/usr/bin/env python3
"""Observe-only detector for floating/mutable registry tag authority risk."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
AUTH_MD = REPO_ROOT / "REGISTRY_AUTHORITY_CLASSIFICATION.md"
REG_AUDIT = REPO_ROOT / "artifacts/registry_audit.json"
OUT_JSON = REPO_ROOT / "artifacts/registry/REGISTRY_FLOATING_TAG_AUDIT.json"
OUT_MD = REPO_ROOT / "reports/registry/REGISTRY_FLOATING_TAG_AUDIT.md"

FLOATING_TAGS = {"latest", "master"}
MUTABLE_ALIASES = {"curl", "stable", "stable-alpine"}
ALLOWED_EXCEPTIONS = {"proof-restore-list", "digest-lock-20260324"}
CLASS_RUNTIME_RISK = "FLOATING_TAG_RUNTIME_RISK"
CLASS_DIAGNOSTIC_ONLY = "FLOATING_TAG_DIAGNOSTIC_ONLY"
CLASS_FORBIDDEN = "FLOATING_TAG_FORBIDDEN"
CLASS_ALLOWED_EXCEPTION = "FLOATING_TAG_ALLOWED_EXCEPTION"


def parse_authority_states(md_text: str) -> dict[str, str]:
    """Parse authority state by canonical image reference."""

    states: dict[str, str] = {}
    for line in md_text.splitlines():
        if not line.startswith("| registry.threadforge.local:30500/"):
            continue
        parts = [p.strip() for p in line.strip().split("|")]
        if len(parts) >= 3:
            states[parts[1]] = parts[2]
    return states


def build_md(payload: dict[str, Any]) -> str:
    """Render markdown report for floating tag findings."""

    lines = [
        "# REGISTRY_FLOATING_TAG_AUDIT",
        "",
        "## Mode",
        "- observe-only",
        "",
        "## Detection Classes",
        "- FLOATING_TAG_RUNTIME_RISK",
        "- FLOATING_TAG_DIAGNOSTIC_ONLY",
        "- FLOATING_TAG_FORBIDDEN",
        "- FLOATING_TAG_ALLOWED_EXCEPTION",
        "",
        "## Summary",
        "",
        f"- total_findings: {payload['summary']['total_findings']}",
        f"- FLOATING_TAG_RUNTIME_RISK: {payload['summary']['FLOATING_TAG_RUNTIME_RISK']}",
        f"- FLOATING_TAG_DIAGNOSTIC_ONLY: {payload['summary']['FLOATING_TAG_DIAGNOSTIC_ONLY']}",
        f"- FLOATING_TAG_FORBIDDEN: {payload['summary']['FLOATING_TAG_FORBIDDEN']}",
        f"- FLOATING_TAG_ALLOWED_EXCEPTION: {payload['summary']['FLOATING_TAG_ALLOWED_EXCEPTION']}",
        "",
        "## Findings",
        "",
        "| tagged_ref | canonical_ref | authority_state | classification | reason |",
        "|---|---|---|---|---|",
    ]

    for row in payload["findings"]:
        lines.append(
            f"| {row['tagged_ref']} | {row['canonical_ref']} | {row['authority_state']} "
            f"| {row['classification']} | {row['reason']} |"
        )

    return "\n".join(lines) + "\n"


def classify_tag_risk(authority_state: str, is_exception: bool) -> tuple[str, str]:
    """Classify floating tag finding and return reason text."""

    if is_exception:
        return (
            CLASS_ALLOWED_EXCEPTION,
            "explicitly allowlisted bounded tag for deterministic replay workflows",
        )
    if authority_state in {"REQUIRED_RUNTIME", "REQUIRED_BOOTSTRAP", "REQUIRED_ROLLBACK"}:
        return (
            CLASS_RUNTIME_RISK,
            "mutable tag intersects runtime/bootstrap/rollback lineage",
        )
    if authority_state in {"REQUIRED_DIAGNOSTIC", "OPTIONAL_FEATURE", "LEGACY_COMPATIBILITY"}:
        return (
            CLASS_DIAGNOSTIC_ONLY,
            "mutable tag confined to non-runtime lineage but still governance risk",
        )
    return (
        CLASS_FORBIDDEN,
        "mutable tag attached to orphan/forbidden/unclassified lineage",
    )


def summarize_findings(findings: list[dict[str, str]]) -> dict[str, int]:
    """Aggregate floating-tag findings by classification."""

    runtime_risk_count = sum(f["classification"] == CLASS_RUNTIME_RISK for f in findings)
    diagnostic_only_count = sum(f["classification"] == CLASS_DIAGNOSTIC_ONLY for f in findings)
    forbidden_count = sum(f["classification"] == CLASS_FORBIDDEN for f in findings)
    allowed_exception_count = sum(f["classification"] == CLASS_ALLOWED_EXCEPTION for f in findings)

    return {
        "total_findings": len(findings),
        CLASS_RUNTIME_RISK: runtime_risk_count,
        CLASS_DIAGNOSTIC_ONLY: diagnostic_only_count,
        CLASS_FORBIDDEN: forbidden_count,
        CLASS_ALLOWED_EXCEPTION: allowed_exception_count,
    }


def _load_inputs() -> tuple[dict[str, str], dict[str, Any], list[str]]:
    """Load authority and registry inputs, returning deterministic skip reasons."""

    skip_reasons: list[str] = []

    if AUTH_MD.exists():
        auth_states = parse_authority_states(AUTH_MD.read_text(encoding="utf-8"))
    else:
        auth_states = {}
        skip_reasons.append("SKIP_INPUT_MISSING: REGISTRY_AUTHORITY_CLASSIFICATION.md")

    if REG_AUDIT.exists():
        reg = json.loads(REG_AUDIT.read_text(encoding="utf-8"))
    else:
        reg = {"registry_inventory": []}
        skip_reasons.append("SKIP_INPUT_MISSING: artifacts/registry_audit.json")

    return auth_states, reg, skip_reasons


def _iter_relevant_inventory(
    inventory: list[dict[str, Any]],
) -> list[tuple[dict[str, Any], bool]]:
    """Filter entries carrying floating tags, mutable aliases, or allowlisted exceptions."""

    relevant: list[tuple[dict[str, Any], bool]] = []
    sorted_inventory = sorted(
        inventory,
        key=lambda item: str(item.get("tagged_ref", "")),
    )
    for item in sorted_inventory:
        tag = item.get("tag")
        if not isinstance(tag, str):
            continue
        lower = tag.lower()
        is_exception = tag in ALLOWED_EXCEPTIONS
        has_mutable_pattern = lower in FLOATING_TAGS or lower in MUTABLE_ALIASES
        if has_mutable_pattern or is_exception:
            relevant.append((item, is_exception))
    return relevant


def _typed_inventory_items(reg: dict[str, Any]) -> list[dict[str, Any]]:
    """Return registry inventory values that are dictionaries."""

    inventory = reg.get("registry_inventory", [])
    if not isinstance(inventory, list):
        return []
    return [item for item in inventory if isinstance(item, dict)]


def _build_finding(
    item: dict[str, Any],
    is_exception: bool,
    auth_states: dict[str, str],
) -> dict[str, str]:
    """Build one floating-tag finding from registry inventory and authority lookup."""

    canonical_any = item.get("canonical_ref", "unknown")
    tagged_any = item.get("tagged_ref", "unknown")
    canonical_ref = canonical_any if isinstance(canonical_any, str) else "unknown"
    tagged_ref = tagged_any if isinstance(tagged_any, str) else "unknown"

    authority_state = auth_states.get(canonical_ref, "UNCLASSIFIED")
    classification, reason = classify_tag_risk(
        authority_state=authority_state,
        is_exception=is_exception,
    )
    return {
        "tagged_ref": tagged_ref,
        "canonical_ref": canonical_ref,
        "authority_state": authority_state,
        "classification": classification,
        "reason": reason,
    }


def main() -> int:
    """Run observe-only floating-tag authority audit and write artifacts."""

    auth_states, reg, skip_reasons = _load_inputs()

    findings: list[dict[str, str]] = []
    typed_dict_inventory = _typed_inventory_items(reg)
    relevant_inventory = _iter_relevant_inventory(typed_dict_inventory)

    for item, is_exception in relevant_inventory:
        findings.append(
            _build_finding(
                item=item,
                is_exception=is_exception,
                auth_states=auth_states,
            )
        )

    summary = summarize_findings(findings)

    payload = {
        "mode": "observe-only",
        "skip_reasons": skip_reasons,
        "summary": summary,
        "findings": findings,
    }

    OUT_JSON.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    OUT_MD.write_text(build_md(payload), encoding="utf-8")

    print(
        "[floating-tag-authority] observe-only: wrote "
        "artifacts/registry/REGISTRY_FLOATING_TAG_AUDIT.json and "
        "reports/registry/REGISTRY_FLOATING_TAG_AUDIT.md"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
