# REGISTRY_PROMOTION_BOUNDARY

## Scope

Design-only promotion boundary scaffold. No runtime automation is implemented in this phase.

## Canonical Promotion Path

source-digest
-> signed-digest
-> authority-classified
-> promotion-approved
-> runtime-eligible

## Required Metadata Per Candidate Digest

- canonical digest reference
- owner domain
- authority state
- purge tier
- rollback dependency
- proof sensitivity
- provenance evidence source
- signature visibility status
- promotion request id and approver identity

## Required Evidence Before Promotion-Approved

- digest immutability proof (same digest across inventory/provenance export)
- signature visibility export record
- authority classification record
- rollback retention window assignment
- floating-tag audit status
- owner attribution status

## Rollback Retention Boundary

- REQUIRED_ROLLBACK and REQUIRED_BOOTSTRAP cannot be demoted without explicit rollback freeze evidence.
- promotion of replacements must preserve at least two validated release-cycle rollback windows.

## CI Boundary Rules

- CI may observe and export governance state.
- CI must not mutate canonical runtime truth.
- CI-generated artifacts are non-authoritative until classified and approved.

## Diagnostic Exclusion Rules

- REQUIRED_DIAGNOSTIC lineages are never runtime-eligible by default.
- runtime promotion requires explicit exception approval with owner and incident linkage.

## Promotion Authority Rules

- promotion-approved requires two-party governance approval:
  - owning domain approver
  - platform governance approver
- approvals must be bound to immutable digest id, never to mutable tag labels.

## Digest Immutability Expectations

- authoritative references must be digest-pinned.
- floating tags are not promotion authority.
- tag aliases may exist for operator ergonomics but cannot grant runtime eligibility.
