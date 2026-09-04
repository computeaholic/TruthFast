#!/usr/bin/env python3
# pylint: disable=line-too-long
"""Observe-only exporter for deterministic registry provenance visibility."""

from __future__ import annotations

import json
import importlib.util
from dataclasses import dataclass
from pathlib import Path
from typing import Any

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

AUTH_MD = REPO_ROOT / "REGISTRY_AUTHORITY_CLASSIFICATION.md"
REG_AUDIT = REPO_ROOT / "artifacts/registry_audit.json"
RUNTIME_DRIFT = REPO_ROOT / "artifacts/runtime/runtime_drift_report.json"
OUT_JSON = REPO_ROOT / "artifacts/registry/REGISTRY_PROVENANCE_EXPORT.json"
OUT_MD = REPO_ROOT / "reports/registry/REGISTRY_PROVENANCE_EXPORT.md"
OUT_AUDIT_MD = REPO_ROOT / "reports/audits/RUNTIME_PROVENANCE_CLOSURE_AUDIT.md"

CRITICAL_STATES = {
    "REQUIRED_RUNTIME",
    "REQUIRED_BOOTSTRAP",
    "REQUIRED_ROLLBACK",
    "REQUIRED_DIAGNOSTIC",
}


@dataclass(frozen=True)
class AuthRow:
    """Authority classification row used to enrich provenance export."""

    image: str
    authority_state: str
    owner: str
    rollback: str
    proof: str


def parse_auth_rows(text: str) -> dict[str, AuthRow]:
    """Parse authority classification table into image->row mapping."""

    rows: dict[str, AuthRow] = {}
    for line in text.splitlines():
        if not line.startswith("| registry.threadforge.local:30500/"):
            continue
        parts = [p.strip() for p in line.strip().split("|")]
        if len(parts) < 7:
            continue
        row = AuthRow(
            image=parts[1],
            authority_state=parts[2],
            owner=parts[3],
            rollback=parts[4],
            proof=parts[5],
        )
        rows[row.image] = row
    return rows


def parse_runtime_signature(runtime_data: dict[str, Any]) -> dict[str, bool]:
    """Collect runtime-evidenced signature visibility by canonical image ref."""

    sig_map: dict[str, bool] = {}
    classified = runtime_data.get("classified", {})
    if isinstance(classified, dict):
        for rows in classified.values():
            if isinstance(rows, list):
                for item in rows:
                    if not isinstance(item, dict):
                        continue
                    ref = item.get("resolved_ref") or item.get("image")
                    if isinstance(ref, str):
                        sig_map[ref] = bool(item.get("is_signed", False))
    return sig_map


def image_repo(image: str) -> str:
    """Extract repository path from canonical registry image reference."""

    return image.split("@", 1)[0].replace("registry.threadforge.local:30500/", "", 1)


def build_md(payload: dict[str, Any]) -> str:
    """Render markdown view of the normalized provenance export."""

    table_header = (
        "| image | digest | tag_lineage | runtime_present | signature_visibility "
        "| provenance_evidence_source | authority_state | visibility_class | owner |"
    )
    lines = [
        "# REGISTRY_PROVENANCE_EXPORT",
        "",
        "## Mode",
        "- observe-only",
        "",
        "## Visibility Classes",
        "- runtime-evidenced",
        "- registry-only",
        "- unverifiable",
        "- missing-export",
        "- rollback-retained",
        "",
        "## Provenance Classification Classes",
        "- PROVENANCE_COMPLETE",
        "- PROVENANCE_PARTIAL",
        "- PROVENANCE_HISTORICAL",
        "- PROVENANCE_MISSING",
        "- OUT_OF_SCOPE",
        "",
        "## Summary",
        "",
        f"- total_images: {payload['summary']['total_images']}",
        f"- runtime-evidenced: {payload['summary']['runtime-evidenced']}",
        f"- registry-only: {payload['summary']['registry-only']}",
        f"- unverifiable: {payload['summary']['unverifiable']}",
        f"- missing-export: {payload['summary']['missing-export']}",
        f"- rollback-retained: {payload['summary']['rollback-retained']}",
        f"- critical_scope_images: {payload['summary']['critical_scope_images']}",
        ("- critical_PROVENANCE_COMPLETE: " f"{payload['summary']['critical_PROVENANCE_COMPLETE']}"),
        ("- critical_PROVENANCE_PARTIAL: " f"{payload['summary']['critical_PROVENANCE_PARTIAL']}"),
        ("- critical_PROVENANCE_HISTORICAL: " f"{payload['summary']['critical_PROVENANCE_HISTORICAL']}"),
        ("- critical_PROVENANCE_MISSING: " f"{payload['summary']['critical_PROVENANCE_MISSING']}"),
        "",
        "## Export Table",
        "",
        table_header,
        "|---|---|---|---|---|---|---|---|---|",
    ]

    for row in payload["rows"]:
        line = (
            f"| {row['image']} | {row['digest']} | {row['tag_lineage']} "
            f"| {row['runtime_present']} | {row['signature_visibility']} "
            f"| {row['provenance_evidence_source']} | {row['authority_state']} "
            f"| {row['visibility_class']} | {row['owner']} |"
        )
        lines.append(line)

    return "\n".join(lines) + "\n"


def build_audit_md(payload: dict[str, Any]) -> str:
    """Render focused runtime provenance closure audit for critical authority states."""

    summary = payload["summary"]
    lines = [
        "# RUNTIME_PROVENANCE_CLOSURE_AUDIT",
        "",
        "## Scope",
        "- REQUIRED_RUNTIME",
        "- REQUIRED_BOOTSTRAP",
        "- REQUIRED_ROLLBACK",
        "- REQUIRED_DIAGNOSTIC",
        "",
        "## Classification",
        f"- PROVENANCE_COMPLETE: {summary['critical_PROVENANCE_COMPLETE']}",
        f"- PROVENANCE_PARTIAL: {summary['critical_PROVENANCE_PARTIAL']}",
        f"- PROVENANCE_HISTORICAL: {summary['critical_PROVENANCE_HISTORICAL']}",
        f"- PROVENANCE_MISSING: {summary['critical_PROVENANCE_MISSING']}",
        "",
        "## Critical Lineage Detail",
        "",
        (
            "| image | authority_state | signed_visibility | source_workflow_visibility "
            "| digest_lineage_visibility | promotion_lineage_visibility "
            "| rollback_lineage_visibility | provenance_classification |"
        ),
        "|---|---|---|---|---|---|---|---|",
    ]

    for row in payload["rows"]:
        if row["authority_state"] not in CRITICAL_STATES:
            continue
        lines.append(
            (
                f"| {row['image']} | {row['authority_state']} "
                f"| {row['signed_visibility']} "
                f"| {row['source_workflow_visibility']} "
                f"| {row['digest_lineage_visibility']} "
                f"| {row['promotion_lineage_visibility']} "
                f"| {row['rollback_lineage_visibility']} "
                f"| {row['provenance_classification']} |"
            )
        )

    return "\n".join(lines) + "\n"


def _load_json(path: Path, skip_reasons: list[str]) -> dict[str, Any]:
    """Load JSON dictionary and record deterministic skip reason on missing input."""

    if not path.exists():
        skip_reasons.append(f"SKIP_INPUT_MISSING: {path.relative_to(REPO_ROOT)}")
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def _build_repo_tags(reg: dict[str, Any]) -> dict[str, set[str]]:
    """Build repository->tag lineage index from registry inventory."""

    repo_tags: dict[str, set[str]] = {}
    inventory = reg.get("registry_inventory", [])
    if not isinstance(inventory, list):
        return repo_tags

    for entry in inventory:
        if not isinstance(entry, dict):
            continue
        repo = entry.get("repo")
        tag = entry.get("tag")
        if isinstance(repo, str) and isinstance(tag, str):
            repo_tags.setdefault(repo, set()).add(tag)
    return repo_tags


def _visibility_class(
    image: str,
    authority_state: str,
    runtime_set: set[str],
    signature_map: dict[str, bool],
) -> str:
    """Classify image provenance visibility.

    Uses runtime, signature, and authority signals only.
    """

    is_rollback_state = authority_state in {
        "REQUIRED_ROLLBACK",
        "LEGACY_COMPATIBILITY",
    }
    if is_rollback_state and image not in runtime_set:
        return "rollback-retained"
    if image in runtime_set and image in signature_map:
        return "runtime-evidenced"
    if image in runtime_set and image not in signature_map:
        return "unverifiable"
    if image not in runtime_set and image not in signature_map:
        return "missing-export"
    return "registry-only"


def _default_auth_row(image: str) -> AuthRow:
    """Return fallback classification row when image is not found in authority table."""

    return AuthRow(
        image=image,
        authority_state="UNCLASSIFIED",
        owner="unassigned",
        rollback="unknown",
        proof="unknown",
    )


def _normalize_one_image(
    image: str,
    runtime_set: set[str],
    repo_tags: dict[str, set[str]],
    signature_map: dict[str, bool],
    auth_rows: dict[str, AuthRow],
) -> tuple[dict[str, str], str]:
    # pylint: disable=too-many-locals
    """Normalize one image into export row and computed visibility class."""

    repo = image_repo(image)
    digest = image.split("@", 1)[1] if "@" in image else "unknown"
    tag_lineage = ", ".join(sorted(repo_tags.get(repo, set()))) or "none"
    runtime_present = "yes" if image in runtime_set else "no"

    if image in signature_map:
        signature_visibility = "visible(true)" if signature_map[image] else "visible(false)"
        evidence = "runtime_drift_report.classified"
    else:
        signature_visibility = "unknown"
        evidence = "missing-export"

    auth = auth_rows.get(image, _default_auth_row(image))
    visibility = _visibility_class(
        image=image,
        authority_state=auth.authority_state,
        runtime_set=runtime_set,
        signature_map=signature_map,
    )

    source_workflow_visibility = (
        "runtime-evidenced"
        if runtime_present == "yes"
        else ("tag-lineage-only" if tag_lineage != "none" else "missing")
    )
    digest_lineage_visibility = "visible" if digest != "unknown" else "missing"
    promotion_lineage_visibility = "visible" if tag_lineage != "none" else "missing"
    rollback_lineage_visibility = "required" if auth.rollback == "required" else "not-required"
    signals = {
        "runtime_present": runtime_present,
        "signed_visibility": signature_visibility,
        "source_workflow_visibility": source_workflow_visibility,
        "digest_lineage_visibility": digest_lineage_visibility,
        "promotion_lineage_visibility": promotion_lineage_visibility,
        "rollback_lineage_visibility": rollback_lineage_visibility,
    }
    provenance_classification = _provenance_classification(
        authority_state=auth.authority_state,
        signals=signals,
    )

    row = {
        "image": image,
        "digest": digest,
        "tag_lineage": tag_lineage,
        "runtime_present": runtime_present,
        "signature_visibility": signature_visibility,
        "provenance_evidence_source": evidence,
        "authority_state": auth.authority_state,
        "visibility_class": visibility,
        "owner": auth.owner,
        "signed_visibility": signature_visibility,
        "source_workflow_visibility": source_workflow_visibility,
        "digest_lineage_visibility": digest_lineage_visibility,
        "promotion_lineage_visibility": promotion_lineage_visibility,
        "rollback_lineage_visibility": rollback_lineage_visibility,
        "provenance_classification": provenance_classification,
    }
    return row, visibility


def _provenance_classification(authority_state: str, signals: dict[str, str]) -> str:
    """Classify provenance completeness for critical authority lineage."""

    if authority_state not in CRITICAL_STATES:
        return "OUT_OF_SCOPE"

    signed_known = signals["signed_visibility"] in {"visible(true)", "visible(false)"}
    source_known = signals["source_workflow_visibility"] in {
        "runtime-evidenced",
        "tag-lineage-only",
    }
    digest_known = signals["digest_lineage_visibility"] == "visible"
    promotion_known = signals["promotion_lineage_visibility"] == "visible"
    rollback_known = signals["rollback_lineage_visibility"] in {
        "required",
        "not-required",
    }

    if signed_known and source_known and digest_known and promotion_known and rollback_known:
        return "PROVENANCE_COMPLETE"
    if (
        authority_state == "REQUIRED_ROLLBACK"
        and signals["runtime_present"] == "no"
        and digest_known
        and promotion_known
    ):
        return "PROVENANCE_HISTORICAL"
    if source_known or digest_known or promotion_known or signed_known:
        return "PROVENANCE_PARTIAL"
    return "PROVENANCE_MISSING"


def _normalize_images(
    registry_set: set[str],
    runtime_set: set[str],
    repo_tags: dict[str, set[str]],
    signature_map: dict[str, bool],
    auth_rows: dict[str, AuthRow],
) -> tuple[list[dict[str, str]], dict[str, int]]:
    """Build normalized provenance rows and aggregate visibility class counts."""

    rows: list[dict[str, str]] = []
    visibility_counts = {
        "runtime-evidenced": 0,
        "registry-only": 0,
        "unverifiable": 0,
        "missing-export": 0,
        "rollback-retained": 0,
    }

    for image in sorted(registry_set):
        row, visibility = _normalize_one_image(
            image=image,
            runtime_set=runtime_set,
            repo_tags=repo_tags,
            signature_map=signature_map,
            auth_rows=auth_rows,
        )
        visibility_counts[visibility] += 1
        rows.append(row)

    return rows, visibility_counts


def _critical_summary(rows: list[dict[str, str]]) -> dict[str, int]:
    """Summarize provenance classification for critical authority scope."""

    critical_rows = [row for row in rows if row["authority_state"] in CRITICAL_STATES]
    return {
        "critical_scope_images": len(critical_rows),
        "critical_PROVENANCE_COMPLETE": sum(
            row["provenance_classification"] == "PROVENANCE_COMPLETE" for row in critical_rows
        ),
        "critical_PROVENANCE_PARTIAL": sum(
            row["provenance_classification"] == "PROVENANCE_PARTIAL" for row in critical_rows
        ),
        "critical_PROVENANCE_HISTORICAL": sum(
            row["provenance_classification"] == "PROVENANCE_HISTORICAL" for row in critical_rows
        ),
        "critical_PROVENANCE_MISSING": sum(
            row["provenance_classification"] == "PROVENANCE_MISSING" for row in critical_rows
        ),
    }


def _load_inputs(
    skip_reasons: list[str],
) -> tuple[dict[str, AuthRow], dict[str, Any], dict[str, Any]]:
    """Load authority, registry audit, and runtime drift inputs."""

    if AUTH_MD.exists():
        auth_rows = parse_auth_rows(AUTH_MD.read_text(encoding="utf-8"))
    else:
        auth_rows = {}
        skip_reasons.append("SKIP_INPUT_MISSING: REGISTRY_AUTHORITY_CLASSIFICATION.md")

    reg = _load_json(REG_AUDIT, skip_reasons)
    runtime_data = _load_json(RUNTIME_DRIFT, skip_reasons)
    return auth_rows, reg, runtime_data


def main() -> int:
    """Run observe-only provenance normalization and export deterministic artifacts."""

    skip_reasons: list[str] = []

    auth_rows, reg, runtime_data = _load_inputs(skip_reasons)

    runtime_images = reg.get("runtime_images", [])
    registry_images = reg.get("registry_images", [])
    runtime_set = set(runtime_images) if isinstance(runtime_images, list) else set()
    registry_set = set(registry_images) if isinstance(registry_images, list) else set()

    repo_tags = _build_repo_tags(reg)

    signature_map = parse_runtime_signature(runtime_data)

    rows, visibility_counts = _normalize_images(
        registry_set=registry_set,
        runtime_set=runtime_set,
        repo_tags=repo_tags,
        signature_map=signature_map,
        auth_rows=auth_rows,
    )

    critical_summary = _critical_summary(rows)

    payload = {
        "mode": "observe-only",
        "skip_reasons": skip_reasons,
        "summary": {
            "total_images": len(rows),
            **visibility_counts,
            **critical_summary,
        },
        "rows": rows,
    }

    out_json_path = resolve_report_output_path(OUT_JSON, repo_root=REPO_ROOT)
    out_md_path = resolve_report_output_path(OUT_MD, repo_root=REPO_ROOT)
    out_audit_md_path = resolve_report_output_path(OUT_AUDIT_MD, repo_root=REPO_ROOT)

    out_json_path.parent.mkdir(parents=True, exist_ok=True)
    out_md_path.parent.mkdir(parents=True, exist_ok=True)
    out_audit_md_path.parent.mkdir(parents=True, exist_ok=True)

    out_json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    out_md_path.write_text(build_md(payload), encoding="utf-8")
    out_audit_md_path.write_text(build_audit_md(payload), encoding="utf-8")

    print(
        "[registry-provenance-export] observe-only: wrote "
        "artifacts/registry/REGISTRY_PROVENANCE_EXPORT.json, "
        "reports/registry/REGISTRY_PROVENANCE_EXPORT.md, and "
        "reports/audits/RUNTIME_PROVENANCE_CLOSURE_AUDIT.md"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
