# Migration Strategy

> Status: historical migration plan. Current system truth lives in the
> operational architecture, proof, and release documentation.

## Goal

Migrate TruthFast from a native-only reference implementation to a constitutional architecture with profile-based deployments while keeping `make validate-all` authoritative and the repository operational at every phase.

## Phases

1. Consolidation (current): create `docs/architecture/` and canonicalize definitions. (COMPLETE)
2. Schema stabilization: publish EC schemas and claim registry; add validators.
3. Provider abstraction: add provider descriptor catalog and translation utilities; keep native implementation unchanged.
4. Profile authoring: create `profile:bigbang` metadata and validation; no implementation movement.
5. Parallel runs: allow `make validate-all` to accept a `--profile` binding that selects providers (feature flagged).
6. Cutover: default workflows reference profiles; native implementation remains available as `profile:native`.

Backwards compatibility

- Each phase maintains `make validate-all` behavior until `--profile` opt-in is stable.

Repository tasks before Big Bang migration

- Add EC schema validators and static profile linter.
- Add provider descriptor catalog and initial Big Bang provider descriptors.
- Extend the repository manifest and Concept Index with claim and Evidence
  Contract identifiers as provider bindings are introduced.
