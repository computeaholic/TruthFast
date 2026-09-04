# Migration Strategy — Big Bang

Phased approach (portable to a new VM)

Phase 0: Preparation

- Validate PAP contents and ensure appendix snapshots present.

Phase 1: Provider staging

- Install provider components on a staging VM; verify provider descriptors and EC outputs.

Phase 2: Proofing and registry

- Configure Proof Registry and exercise collectors; produce EC instances and freeze artifacts.

Phase 3: Evaluation and certification

- Run Evaluators to assert Claims; produce certification artifacts per policy.

Phase 4: Cutover and validation

- Run full `make validate-all --profile=profile:bigbang:v1` (feature gate) or follow supplied command sequence in `09-Implementation-Sequence.md`.

Rollback and safety

- Each phase must leave the system operational; use immutability and fail-closed reviewer checks.
