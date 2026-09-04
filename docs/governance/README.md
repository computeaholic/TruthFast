# governance/

Purpose: governance for repository execution, registry retention, promotion, and
diagnostic boundaries.

What belongs here:

- governance plans
- CI execution boundary
- retention policy
- promotion boundaries

What does not belong here:

- runtime code
- proof outputs
- historical reports

Owner: Governance

Primary consumers:

- architecture reviewers
- platform maintainers
- validation authors

Validation entry points:

- `mkdocs build`
- `scripts/verify/verify_repository_topology.sh`

Related documents:

- `REGISTRY_DIAGNOSTIC_ISOLATION_PLAN.md`
- `REGISTRY_GOVERNANCE_ENFORCEMENT_PLAN.md`
- `REGISTRY_PROMOTION_BOUNDARY.md`
- `REGISTRY_RETENTION_POLICY.md`

## CI Execution Boundary

GitHub CI proves repository truth. Operator-controlled native execution proves
runtime truth. Green CI does not qualify the TruthFast runtime, and missing or
failed remote checks do not retroactively invalidate an exact-SHA runtime
qualification.

The machine authority for CI is
`platform/config/ci_execution_allowlist.json`, enforced by
`scripts/verify/ci_audit.py`. Workflows may use only the exact commands, actions,
test files, runner, and transitively classified helpers recorded there. CI may
reach only `CI_STATIC`, `CI_UNIT`, `CI_DOCS`, and `CI_GOVERNANCE` paths. Runtime,
assurance, destructive, and secondary-runtime entrypoints are prohibited.

Repository-only workflows use a pinned GitHub-hosted runner so they do not
inherit the Docker, sudo, cluster, registry, or signing authority of the native
TruthFast host.
