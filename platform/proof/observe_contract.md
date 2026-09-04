# Observe Contract

## Scope

The observe phase is the authoritative proof boundary for live observability behavior after verify has already established policy and runtime correctness.

## What Observe Guarantees

1. Signals are emitted through the configured observability ingestion paths.
2. Signals are ingested by the live observability stack.
3. Signals are queryable through the live Loki, Tempo, and Prometheus APIs used by proof.
4. Cross-system correlation is possible across the same live endpoints and query paths used elsewhere in proof.
5. Every observe script invoked by the observe phase declares its class with `export OBSERVE_TYPE=<INGEST|QUERY|CORRELATION|LIVENESS>`.
6. Every observe failure produces inspectable evidence in `artifacts/debug/observe_failure.log`.

## What Observe Must Not Do

1. Observe must not mutate the system.
2. Observe must not rely on timing guesses or silent delay-based success assumptions.
3. Observe must not fail without evidence.
4. Observe must not produce an empty phase log.

## Observe Classes

### `INGEST`

Meaning: emits signals into the observability stack and validates write-path acceptance.

### `QUERY`

Meaning: reads live observability APIs and validates query-path availability.

### `CORRELATION`

Meaning: proves that related signals can be correlated across multiple observability backends.

### `LIVENESS`

Meaning: validates that required observability components are reachable and ready.

## Enforcement

1. Missing `OBSERVE_TYPE` is a `CONTRACT_VIOLATION`.
2. Invalid `OBSERVE_TYPE` is a `CONTRACT_VIOLATION`.
3. A non-zero observe exit with an empty `observe.log` is an `INTERNAL_ERROR`.
4. A failed observe check without `artifacts/debug/observe_failure.log` is an `INTERNAL_ERROR`.
