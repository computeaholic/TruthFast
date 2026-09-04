# ThreadForge Constitution — Snapshot (excerpt)

This file contains a generated snapshot excerpt of `docs/architecture/01-Constitution.md` to provide portable constitutional context within the PAP.

Purpose: The Constitution establishes the canonical, versioned set of architectural objects that are immutable by implementation: Capabilities, Claims, Evidence Contracts, Providers, Profiles, and Governance primitives.

Architectural invariants (excerpt):

- Every Claim belongs to exactly one Capability.
- Every Proof maps to exactly one Claim.
- Evidence Contracts are the only permitted artifact-level interface between Collectors and Evaluators.
