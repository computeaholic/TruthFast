# TruthFast Observability Operations

This guide describes the current observability surface for the trust-root-lifecycle
contract.
It is operational, not historical.

## Purpose

The observability stack exists to explain the current trust-root lifecycle at a glance:

- runtime lifecycle state
- active root presence
- successor preparation state
- continuous successor continuity
- proof status

The observability surface is split across the Grafana dashboard and Prometheus rules
backing the lifecycle contract.

## Dashboard

The lifecycle dashboard presents the following signals:

- `threadforge_trust_continuity_state_code`
- `Continuity State`
- `Prepare Due`
- `Activate Due`
- `threadforge_trust_prepare_window_missing_successor`
- `Active Root Present`
- `Prepared Root Present`
- `Prepared Published`
- `Prepared Key Present`
- `Successor Count`
- `Valid Root Count`
- `Continuous Successor Policy`
- `Coverage Gap`
- `Prepare Window Missing Successor`
- `SPIRE Lifecycle OK`

The dashboard should make the current state obvious without opening logs.

## Lifecycle states

The lifecycle state is defined by the runtime contract and visualized through
the continuity-state recording rule.

- `ACTIVE_ONLY`
  - `prepare_due=false`
  - no successor is required yet
  - this is healthy and must not alert
- `PREPARE_DUE`
  - `prepare_due=true`
  - a SPIRE-prepared successor must be present
- `ACTIVE_PLUS_PREPARED`
  - `prepare_due=true`
  - a SPIRE-prepared successor is present
- `ROTATING`
  - `prepare_due=true`
  - activation is due and successor overlap exists
- `VIOLATION`
  - the SPIRE lifecycle contract is not healthy

## Alerts

The current fail-closed alerts are:

- `TrustRootPrepareWindowMissingSuccessor`
  - fires when `prepare_due=true` and no SPIRE-prepared successor satisfies the continuity contract
- `TrustRootContinuityLost`
  - fires when SPIRE lifecycle health is false

These alerts do not fire for `ACTIVE_ONLY`.

## Expected behavior

- `ACTIVE_ONLY` remains green while no successor is required.
- `prepare_due=true` without a SPIRE-prepared successor fails closed immediately.
- SPIRE-prepared successor presence, publication, and key state remain visible in the dashboard.
- continuity and proof status should agree with the runtime lifecycle contract.
