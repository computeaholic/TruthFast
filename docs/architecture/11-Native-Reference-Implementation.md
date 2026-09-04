# Native Reference Implementation

## Purpose

Describe how the existing TruthFast codebase maps to the constitutional architecture. This document is a reference map only; it does not change code.

Mapping conventions

- `Capability` → capability id
- `Claim` → claim id
- `Evidence Contract` → ec:id
- `Provider` → provider_id
- `Binding` → profile/manifest reference

Representative mappings (examples)

- `scripts/verify/verify_status_signature.sh` → Evidence Contract: `ec:status-signature`; Claim: `claim.artifact.immutable`; Provider: `provider:signing/native`.
- `scripts/verify/verify_trust_continuity.sh` → Claim: `claim.trust.continuity`; ECs: `ec:trust-authority-state`.

Inventory and traceability

- The [Concept Index](17-Concept-Index.md) and
  [repository manifest](repository-manifest.yaml) map constitutional ownership
  to native surfaces. Executable phase guarantees and dependencies are owned by
  `scripts/contracts/proof_phase_contracts.json`.

Important note

- The native implementation is authoritative as an example, but constitutional changes do not permit native implementation to inject new constitutional objects without ADR approval.
