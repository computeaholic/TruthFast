# Constitutional Principles

This document collects the permanent principles that guide TruthFast architecture. Each principle includes purpose, invariant, examples, non-examples, and dependencies.

1. Implementation Independence

- Purpose: Keep the constitution product-agnostic.
- Invariant: No constitutional object names or invariants reference a product-specific API.
- Example: Claims reference "signed artifact" not "cosign signature".
- Non-example: Contract that requires `cosign` as the only signing tool.

2. Deterministic Proofs

- Purpose: Canonical evidence projections must be reproducibly comparable.
- Invariant: Equivalent supported inputs produce stable semantic projections;
  operation-specific timestamps, UUIDs, signatures, and logs may differ.
- Example: Stable-sort hash manifests and source-bound canonical status.

3. Fail-Closed Assurance

- Purpose: Conservative safety when required evidence is missing.
- Invariant: Missing, blocked, or unevaluated mandatory evidence prevents final
  `PASS`; it is not converted into a lower-confidence success.

4. Minimal Constitutional Surface

- Purpose: Reduce long-term maintenance and drift.
- Invariant: Additions require ADR approval and owner assignment.
