# REGISTRY_GOVERNANCE_ENFORCEMENT_PLAN

## Scope
Design-only policy plan. No implementation or deletion in this phase.

## Enforcement Controls
1. Ownership attribution gate: every new digest requires owner_domain and owning team metadata.
2. Signature visibility gate: admission to authoritative registry requires machine-readable signature status export.
3. Retention classification gate: each digest must include one authority state and one purge tier hint.
4. Expiration policy gate: non-runtime artifacts require explicit expiry date or freeze exemption.
5. Rollback classification gate: runtime-adjacent images require rollback_dependency and rollback window annotation.
6. Tag authority gate: block floating tags (latest/master/curl) from authoritative promotion paths.
7. Orphan prevention gate: nightly report for unreferenced digests older than retention threshold.

## Control Plane Artifacts
- authority index: image -> state, owner, rollback dependency, proof sensitivity
- provenance index: image -> signature export, source workflow, build identity
- lifecycle index: image -> retention window, expiry, purge tier, freeze flags

## Enforcement Sequence
1. Observe mode: emit violations only.
2. Soft fail mode: block new noncompliant additions, preserve existing inventory.
3. Hard fail mode: authoritative promotion requires all policy fields.

## Explicit Non-Goals
- No runtime proof semantic changes.
- No deterministic behavior changes.
- No SPIRE/identity flow changes.
