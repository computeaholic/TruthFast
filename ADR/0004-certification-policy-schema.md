# ADR 0004: Certification Policy Schema

Status: Proposed

## Context

Certification policies map claim sets and confidence thresholds to certification artifacts. A stable machine-readable policy schema is required.

## Decision

Define a policy schema including: policy_id, required_claims, minimum_confidence (per-claim), freshness_window, expiration_defaults, revocation_rules. Policies are versioned and must be recorded in Governance.

## Consequences

- Certifiers must implement policy schema parsing and enforcement.
- Policy changes affecting certification require ADRs.
