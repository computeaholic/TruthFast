# ADR 0002: Evidence Contract Versioning and Migration

Status: Proposed

## Context

Evidence Contracts (ECs) are critical interfaces between collectors and evaluators. Schema changes must be controlled to avoid breaking validators and proofs.

## Decision

Adopt semantic versioning for ECs. Minor (non-breaking) updates increment minor version; breaking changes require ADR + migration plan + translator deliverables.

## Consequences

- Validators must accept EC versions and reject unsupported major versions.
- Migration ADRs required for EC breaking changes.
