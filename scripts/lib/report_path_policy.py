"""Canonical report/artifact routing policy for pre-write enforcement."""

from __future__ import annotations

from pathlib import Path


class ReportPathPolicyError(ValueError):
    """Raised when an output path violates report/artifact routing policy."""


def resolve_report_output_path(raw_path: str | Path, *, repo_root: Path) -> Path:
    """Resolve and validate output path before any file open/write operation."""

    requested = Path(raw_path).expanduser()
    resolved = (repo_root / requested).resolve() if not requested.is_absolute() else requested.resolve()
    root = repo_root.resolve()

    try:
        rel = resolved.relative_to(root)
    except ValueError as exc:
        raise ReportPathPolicyError(f"output path escapes repository root: {raw_path}") from exc

    if not rel.parts:
        raise ReportPathPolicyError("output path must not target repository root")

    top = rel.parts[0]
    if top not in frozenset({"reports", "artifacts"}):
        raise ReportPathPolicyError(f"output path must route to reports/* or artifacts/*, got: {raw_path}")

    if len(rel.parts) == 1:
        raise ReportPathPolicyError(f"output path must include namespace below {top}/, got: {raw_path}")

    if resolved.parent == root:
        raise ReportPathPolicyError("output path must not create files at repository root")

    return resolved
