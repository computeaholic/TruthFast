# Proof Architecture

## Current V1 Scope

Proof Architecture defines how source-bound runtime evidence is collected,
evaluated, aggregated, frozen, signed, and verified. Current V1 uses a local
canonical proof tree under `artifacts/proof/latest/`; it does not operate a
separate Proof Registry service or claim independent semantic replay.

Core components:

- **Collectors** produce owner-attributed observations and artifacts.
- **Evaluators** consume declared evidence and decide named guarantees.
- **Aggregation** requires every mandatory phase and guarantee to reach an
  acceptable result; missing, blocked, and unevaluated checks cannot become
  `PASS`.
- **Proof artifacts** freeze the canonical status and evidence manifest.
- **Integrity verification** hashes, signs, verifies, and binds the proof tree
  to the source SHA and operation identity available to that run.

## Operation Contract

Proof evaluates an identity-bound operation, not a collection of component
health checks. Each operation has one producer and the following ordered
contract:

1. **Preconditions**: snapshots establish whether the operation may begin.
2. **Execution**: the producer performs the bounded state transition.
3. **Completion**: evidence binds the terminal state to the exact operation
   identity rather than reconstructing identity from names, labels, or list
   ordering.
4. **Guarantees**: witnesses observe whether the declared invariants held for
   that operation.
5. **Evidence**: collectors preserve the producer-bound observations and their
   provenance.
6. **Certification**: policy interprets the resulting proof without changing
   its execution semantics.

Witnesses do not retry, repair, or reinterpret canonical producer-owned state.
Declared active witnesses may create and restore their own isolated fixtures;
that does not grant them authority to heal the runtime object being judged.
Snapshots establish predicates at one instant and do not imply continuity.
Completion and guarantees remain separate: completion establishes that the
identified operation reached a terminal state, while guarantees state what was
established about that operation.

## Proof Lifecycle

1. **Collect:** owner-specific collectors capture live runtime and
   producer-published state.
2. **Evaluate:** verifiers apply declared guarantee semantics and preserve
   `PASS`, `FAIL`, `BLOCKED`, and `NOT_EVALUATED` distinctions.
3. **Aggregate:** the orchestrator validates phase reachability, guarantee
   coverage, and exit semantics.
4. **Freeze:** canonical artifacts are finalized under
   `artifacts/proof/latest/` with an integrity manifest.
5. **Sign and verify:** proof status and manifests are signed and verified.
6. **Bind:** `commit.sha`, run identity, completion evidence, and the retained
   artifacts identify the source and execution to which the conclusion belongs.

## Determinism and Re-execution

Determinism is defined over canonical semantic projections. Timestamps, UUIDs,
pod names, signatures, logs, and other operation-specific bytes may differ.
Equivalent supported inputs must produce the same canonical status and evidence
projection; security-bearing differences must remain visible.

V1 replay language means cryptographic verification, deterministic projection,
and bounded producer-path re-execution under the same contracts. It does not
mean that a separately owned implementation independently re-decides every
semantic claim. That stronger boundary is post-V1 research.

Evaluator identity and version are recorded where current owners expose them,
but V1 does not claim universal evaluator-version provenance across every
component.

## Versioning

Proof schemas and phase contracts carry explicit versions where consumed. Any
future portable Proof Registry or independent replay boundary requires a new
accepted architecture decision and cannot silently become current V1 authority.

The exact truth model and failure classifications are normative in
[`docs/CANONICAL/PROOF_CONTRACT.md`](../CANONICAL/PROOF_CONTRACT.md).
