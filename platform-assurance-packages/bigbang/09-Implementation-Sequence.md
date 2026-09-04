# Implementation Sequence — Big Bang

This sequence assumes a clean VM. Follow these high-level steps; the PAP is self-contained and provides required artifacts and snapshots.

1. Provision VM and network prerequisites.
2. Stage provider descriptor inventory (see `04-Provider-Mappings.md`).
3. Deploy provider components in staging (SPIRE, Harbor, cosign key access, monitoring stack) or configure access to existing services.
4. Configure Proof Registry (object storage) and ensure signer keys are provisioned.
5. Run collectors to produce EC instances and freeze them into the registry.
6. Run evaluators to assert claims and produce certification artifacts.
7. Execute validation plan (`10-Validation-Plan.md`) and verify acceptance criteria.

Each step includes rollback checkpoints and verification points; see `10-Validation-Plan.md` for details.
