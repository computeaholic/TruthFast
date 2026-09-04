# TruthFast Constitution

## Purpose

The Constitution establishes the canonical, versioned set of architectural
objects whose meaning implementation cannot silently redefine: Capabilities,
Claims, Evidence Contracts, Providers, Profiles, and Governance primitives.

## Scope

Applies to all TruthFast artifacts and profiles. Implementation code (scripts, operators, runtime artifacts) must not redefine constitutional objects.

## Architectural invariants

- Every Claim belongs to exactly one Capability.
- Every proof guarantee maps to a declared claim or invariant; one proof may
  aggregate multiple guarantees.
- Evidence Contracts define declared producer-evaluator interfaces. Current
  owner-specific evidence schemas remain authoritative where mapped by the
  native proof contract.
- Profiles contain only bindings and provider descriptors; profiles never create new Claims or Capabilities.

## Dependency rules

- Constitutional objects may depend only on other constitutional objects.
- Implementations (providers, native components) depend on constitutional objects but constitutional objects do not depend on any implementation.

## Ownership rules

- The `architecture/` documents are the authoritative source of constitutional definitions.
- Each Capability and Evidence Contract must have a named owner (person or team) recorded in Governance.

## Evolution rules

- Constitutional changes require an ADR, two-stage review, and an incremented Constitution version.
- Evidence Contract changes must preserve compatibility or follow a defined migration policy (see Governance).

## Objects that may never become implementation specific

- Capability names and semantics
- Claim identifiers and invariants
- Evidence Contract schema and retention semantics
- Proof truth, integrity, source-binding, and publication semantics
