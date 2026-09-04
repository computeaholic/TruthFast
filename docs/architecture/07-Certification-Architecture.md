# Certification Architecture

## Current V1 Model

Certification is the governed interpretation of validated proof. It does not
execute the runtime, repair producer state, or acquire authority merely by
publishing a status. Current V1 certification is the exact-SHA qualification
record and its source-bound evidence set, not a continuously running Certifier
service or a deployed Proof Registry.

The current conclusion is assembled from distinct operations:

- destructive Golden Boot;
- canonical proof and semantic determinism;
- bounded active assurance;
- two supported demo aggregates;
- controlled SPIRE outage evidence;
- isolated proof-tamper rejection;
- registry and canonical audits; and
- `verify-main` integrity and source-binding checks.

Those operations may share a source SHA without sharing a run ID. The
certification baseline preserves each operation identity and does not describe
the qualification as one execution.

## Acceptance Boundary

A V1 qualification conclusion requires:

1. the declared supported profile and entrypoint;
2. complete mandatory phase and guarantee coverage;
3. no accepted `FAIL`, `BLOCKED`, or `NOT_EVALUATED` guarantee;
4. signed and verified proof artifacts;
5. proof source binding to the executable SHA;
6. semantic determinism for the canonical projection; and
7. the operation-specific evidence named by the qualification record.

Remote GitHub checks are repository/governance diagnostics and remain
non-blocking for runtime qualification. Green CI does not certify runtime
behavior, and a missing remote check does not retroactively invalidate an
already qualified runtime SHA.

## Freshness and Descendants

Qualification remains bound to the executable source revision that ran. A
later documentation-only descendant may publish or clarify the retained
evidence without acquiring runtime qualification. Any executable-tree change
requires a new candidate and operator-controlled qualification.

Current V1 does not issue generally revocable, time-bounded certification
tokens, assign universal confidence scores, or migrate authority to Governance
Receipts or independent semantic replay. Those concepts require separately
accepted post-V1 architecture before they can become current authority.

## Current Authority

[`docs/releases/CERTIFICATION_BASELINE.md`](../releases/CERTIFICATION_BASELINE.md)
is the current qualification record. The canonical proof contract defines
proof truth; the support contract defines native and secondary entrypoints; and
the baseline states the bounded conclusion those artifacts justify.
