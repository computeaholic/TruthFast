# platform/

Purpose: runtime deployment, build, and cluster substrate.

What belongs here:

- Kubernetes manifests
- container build definitions
- runtime configuration
- platform-specific controllers and entrypoints

What does not belong here:

- historical reports
- proof logs
- ad hoc validation output
- documentation that does not describe platform behavior

Owner: Platform Runtime

Primary consumers:

- `scripts/infra/*`
- bootstrap logic
- runtime verification

Validation entry points:

- `make validate-all`
- `scripts/infra/bootstrap.sh`
- `scripts/infra/preload_registry.sh`

Related architecture:

- `docs/architecture/16-Repository-Information-Model.md`
- `docs/CANONICAL/ARCHITECTURE.md`
