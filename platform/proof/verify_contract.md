# Verify Contract

## Scope

The verify phase is the authoritative proof boundary for post-bootstrap system guarantees that can be checked reproducibly from the current cluster and proof artifacts.

## What Verify Guarantees

1. Read-only assertions in verify are evaluated against live cluster state or proof artifacts with deterministic inputs.
2. Liveness checks in verify fail only on observed non-convergence, not on wrapper-path ambiguity.
3. Event consistency checks in verify must bind evidence to the current proof run via `run_id`.
4. Every verify failure must produce an evidence artifact that can be inspected without rerunning the phase.
5. Every verify script invoked by the verify phase must declare its class with `export VERIFY_TYPE=<READ_ONLY|ACTIVE|LIVENESS|EVENT>`.

## What Verify Does Not Guarantee

1. Verify does not perform cluster mutation in read-only proof mode.
2. Verify does not repair the system or retry until success.
3. Verify does not infer success from absence of errors; it requires positive evidence.
4. Verify does not treat ACTIVE checks as authoritative in `make proof`; they belong in `make proof-active`.

## Check Classes

### `READ_ONLY_ASSERTION`

Meaning: Reads cluster state, logs, metrics, or proof artifacts without mutating system state.

Script declaration:

```bash
export VERIFY_TYPE=READ_ONLY
```

Allowed in `make proof`: yes.

### `ACTIVE_VALIDATION`

Meaning: Mutates cluster state, workloads, admission inputs, or runtime control paths in order to validate behavior.

Script declaration:

```bash
export VERIFY_TYPE=ACTIVE
```

Allowed in `make proof`: no.

Allowed in `make proof-active`: yes.

### `LIVENESS_CHECK`

Meaning: Validates time-bound convergence or readiness using live runtime signals.

Script declaration:

```bash
export VERIFY_TYPE=LIVENESS
```

Allowed in `make proof`: yes.

### `EVENT_CONSISTENCY`

Meaning: Validates run-scoped event delivery, telemetry correlation, or notifier/log consistency.

Script declaration:

```bash
export VERIFY_TYPE=EVENT
```

Allowed in `make proof`: yes.

## Enforcement

1. Missing `VERIFY_TYPE` is a `CONTRACT_VIOLATION`.
2. Invalid `VERIFY_TYPE` is a `CONTRACT_VIOLATION`.
3. `VERIFY_TYPE=ACTIVE` under `VERIFY_EXECUTION_MODE=proof` is not executed and must be reported explicitly as `BLOCKED` in proof mode.
4. Any verify failure without an evidence artifact is an internal verify error.
