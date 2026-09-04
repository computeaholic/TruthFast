# Canonical Architecture

The native TruthFast reference implementation operates as a fail-closed proof
harness over a Kubernetes runtime.

`make validate-all` is the canonical runtime authority. GitHub Actions is
repository/static/governance-only and does not boot, prove, or certify the
native runtime.

`make golden-boot` is the canonical destructive reconstruction path for the
native Kind runtime.

## Execution model
- Proof entrypoint: `make proof`
- Orchestrator: `scripts/prove_system.sh`
- Enforcement checks: `scripts/verify/*`

## Control model
- `scripts/prove_system.sh` runs ordered phases and derives final status from current execution only.
- Any contract violation or phase failure drives final failure.
- `STRICT_MODE=true` is enforced for proof execution.

## Authoritative components
- SPIRE identity authority
- Istio data/control planes with SPIRE-rooted identity path
- Kubernetes admission and runtime policy controls
- Observability stack (Loki/Tempo/Grafana-backed checks)

## Runtime evidence model
The system emits proof artifacts to `artifacts/proof/latest/` and verifies signed evidence plus invariant re-checks.
