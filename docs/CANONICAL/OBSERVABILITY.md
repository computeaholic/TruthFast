# Canonical Observability Model

Observability is a proof prerequisite and verification surface, not an advisory check.

## Observability Truth Requirement

Observability proof requires **retrievable stored evidence** from real enforcement traffic.

- Counter increments alone are not sufficient — a counter that increments on a synthetic event does not prove enforcement happened.
- Synthetic signals are not accepted — probes must pass through the actual enforcement path.
- Stack absence is a `MISSING_PREREQ` proof failure, not a skip.

## Required observability outcomes

- Observability stack is deployed and healthy (Loki, Tempo, Grafana, Prometheus).
- Trace-log correlation checks pass against real admission and routing events.
- Observe phase retrieves stored log entries and span data from live enforcement traffic.
- Contract violations in verification logs fail proof.

## Enforcing scripts

- `scripts/verify/verify_observability_stack.sh` — stack health check (prerequisite gate)
- `scripts/verify/verify_trace_log_correlation.sh` — correlate real traces with log entries
- `scripts/verify/validate_observability.sh` — retrieve and validate stored evidence

## Evidence surfaces

- `artifacts/proof/latest/observe.log` — observation phase output
- `artifacts/proof/latest/observability.json` — observability validation artifact (signed)
- `artifacts/proof/latest/verify.log` — full verification output
- `artifacts/proof/latest/observability_prereq.log` — stack readiness log

## Proof integration

The observability prerequisite check runs as its own phase (`observability_prereq`). If it fails, subsequent proof phases do not run — there is no observability-degraded proof path. Either the stack is operational and proof runs, or proof fails with `MISSING_PREREQ`.

The observe phase (`observe`) validates behavioral evidence: allow traffic produces traces, deny decisions appear in logs, egress blocking is recorded. All three must pass with retrieved evidence.
