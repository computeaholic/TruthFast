"""Pure policy for relating a runtime image ID to its deployed image spec."""

from __future__ import annotations

from collections.abc import Collection


VALID_PROJECTION_KINDS = frozenset(
    {"exact_digest", "manifest_projection", "kind_import_alias"}
)


def classify_runtime_projection(
    spec_ref: str,
    runtime_ref: str,
    spec_fingerprints: Collection[object],
    runtime_fingerprints: Collection[object],
    internal_prefix: str,
) -> str:
    """Classify a runtime ref without trusting its digest spelling alone."""
    if not spec_ref or not runtime_ref:
        return "missing_digest"
    if not spec_ref.startswith(internal_prefix) or not runtime_ref.startswith(internal_prefix):
        return "external_runtime_digest"
    if spec_ref == runtime_ref:
        return "exact_digest"
    if set(spec_fingerprints).intersection(runtime_fingerprints):
        return "manifest_projection"
    return "unexplained_runtime_digest"


def approved_runtime_projection(
    spec_ref: str,
    runtime_ref: str,
    spec_fingerprints: Collection[object],
    runtime_fingerprints: Collection[object],
    signed_spec_refs: Collection[str],
    internal_prefix: str,
) -> bool:
    """Require both an admissible relationship and a signed parent ref."""
    kind = classify_runtime_projection(
        spec_ref,
        runtime_ref,
        spec_fingerprints,
        runtime_fingerprints,
        internal_prefix,
    )
    return kind in VALID_PROJECTION_KINDS and spec_ref in set(signed_spec_refs)
