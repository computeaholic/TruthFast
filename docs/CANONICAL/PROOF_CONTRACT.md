# Canonical Proof Contract

This document defines canonical proof execution and every proof status
classification. `make proof` is a non-healing witness with bounded active
assurance. It is not literally read-only.

## Execution Boundary

Canonical proof may:

- read live runtime and producer-published state;
- write evidence under the proof artifact directory;
- execute declared `ACTIVE` verifiers;
- create and remove isolated test fixtures; and
- restore state changed by its own bounded experiment.

Canonical proof must not:

- reconcile, repair, or heal canonical producer-owned state;
- synthesize PASS from a blocked or unevaluated guarantee;
- silently execute an active verifier as a passive claim; or
- suppress a required verifier failure.

Bootstrap and reconciliation scripts own convergence. Proof judges their
published state. A producer defect remains a proof failure until its producer
is run or repaired outside proof.

## Truth-Model Fields

| Field | Meaning |
| --- | --- |
| `passive_guarantees` | Aggregate of guarantees classified as passive observation |
| `active_guarantees` | Aggregate of explicitly classified bounded active guarantees and their top-level negative-test results |
| `proof_heals_canonical_state` | Must be `false` |
| `proof_mutation_mode` | `bounded_active_assurance` for canonical `make proof`, `passive_only` when active checks are excluded, or `active_assurance` for the explicit active mode |
| `read_only_guarantees` | Deprecated compatibility alias of `passive_guarantees`; validators reject disagreement |
| `blocked_guarantees` | Required guarantees blocked by execution policy or an upstream state |
| `not_evaluated_guarantees` | Guarantees not reached because an upstream dependency failed |

The classification authority is
`scripts/contracts/proof_guarantee_classes.json`. A guarantee cannot be
silently moved between passive and active aggregates by a consumer.

## Status Values

### `PASS`

All passive and bounded active guarantees validated against live runtime state.

Requirements:

- `final: PASS` in the finalized proof status;
- `fail_class: NONE`;
- every defined guarantee has `status: PASS`;
- `passive_guarantees: PASS` and `active_guarantees: PASS`;
- `blocked_guarantees` and `not_evaluated_guarantees` are empty;
- `proof_heals_canonical_state: false`;
- `ADVISORY_COUNT: 0` under strict mode;
- proof artifacts are signed and verified; and
- semantic determinism validation passes.

PASS does not mean production readiness, HA certification, universal threat
coverage, or portability beyond the qualified profile.

### `FAIL`

At least one required phase, guarantee, integrity check, or exit-semantics
contract failed. Read the first failing verifier evidence and repair the owning
producer. Never mask a FAIL by suppressing a check.

### `BLOCKED`

A required guarantee could not execute because its declared execution path was
prohibited or unavailable. BLOCKED is not PASS and canonical finalization does
not accept a non-empty `blocked_guarantees` list.

### `NOT_EVALUATED`

A guarantee was not reached because an upstream proof dependency failed.
NOT_EVALUATED remains distinct from FAIL and PASS, and canonical finalization
does not accept it.

### `DENIED_POLICY`

An admission request was explicitly rejected by a Kyverno policy or
ValidatingAdmissionPolicy. This is a successful negative test when the named
policy denial is the expected behavior.

### `DENIED_FAIL_CLOSED_TIMEOUT`

An admission request was rejected because an admission webhook timed out and
`failurePolicy: Fail` rejected it. This is incidental fail-closed protection,
not proof of the intended policy rule.

### `MISSING_PREREQ`

A prerequisite for proof execution is absent. The result is not a successful
security verdict; the owning producer or environment must converge before the
proof can be evaluated.

### `CONTRACT_VIOLATION`

The proof methodology or artifact contract is inconsistent. Examples include
an undeclared active verifier, a mutation mode that contradicts execution, a
healing claim, an invalid trust-root selection, or an exit code inconsistent
with the declared status. Contract violations fail closed.

## Guarantee Classification

| Guarantee type | Description |
| --- | --- |
| Passive | Observes produced state without changing the evaluated runtime object |
| Active | Performs a declared, bounded negative or continuity experiment and restores its own fixture/state |
| Blocked | Required path was prohibited or unavailable; never converted to PASS |
| Not evaluated | Upstream failure prevented evaluation; never converted to PASS |

Canonical `make proof` intentionally includes the active classification. The
separate `make prove-active` surface remains available for explicit active-mode
execution, but its existence does not make canonical proof passive-only.

## Determinism Contract

Determinism is semantic projection determinism, not bitwise identity of logs,
timestamps, UUIDs, signatures, pod names, IP addresses, or other
operation-specific values. Two equivalent runs must produce the same canonical
status and evidence projections. Security-bearing projection drift is a
contract violation.

## Evidence Integrity Boundary

Signed evidence proves artifact integrity and source/run binding. It does not,
by itself, prove the truth of a runtime claim without the verifier and producer
chain that generated the artifact.

## Workload Projection Continuity

Identity-bearing workload projection remains continuous from canonical source
through rendered manifest, applied workload, and running pod. Proof binds the
chain using owner references and UID continuity rather than unordered label
discovery.
