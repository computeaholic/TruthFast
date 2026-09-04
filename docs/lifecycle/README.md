# lifecycle/

Purpose: lifecycle classification and execution matrices for retained registry state.

What belongs here:

- purge matrices
- retention classifications
- lifecycle evidence

What does not belong here:

- runtime code
- proof outputs
- active documentation duplicates

Owner: Lifecycle

Primary consumers:

- governance
- operations
- auditors

Validation entry points:

- `mkdocs build`
- `scripts/verify/verify_repository_topology.sh`

Related documents:

- `REGISTRY_PURGE_EXECUTION_MATRIX.md`
- `REGISTRY_RETENTION_CLASSIFICATION.md`
