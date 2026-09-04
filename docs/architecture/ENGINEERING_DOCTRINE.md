# TruthFast Engineering Doctrine

This document records implementation-independent rules used to review the
current TruthFast architecture. It is not a new runtime authority. Canonical
behavior remains owned by the support contract, producers, verifiers, and
qualification paths named elsewhere in this repository.

The complete research record and law-by-law adjudication are separate:

- `reports/research/threadforge-failed-assumption-doctrine-20260828/`
- `docs/architecture/system-model/research_doctrine_matrix.json`

## Evidence before declaration

Declared state is intent, not proof. TruthFast follows state from its
producer through distribution and load-bearing consumers, then exercises the
behavior when the claim requires it. A controller reporting success or a
manifest containing a policy is not enough by itself.

An observed command result is also not authoritative post-state. Convergence
must compare intended postconditions with the authoritative state before a
retry or conclusion is justified.

## Producers own state; witnesses do not heal it

The producer that owns a transition owns its repair. Proof, audit, and
certification consume evidence; they do not reconcile producer-owned runtime
state or translate a required failure into success. Bounded active assurance
may create and restore isolated fixtures, but it may not heal the canonical
object being evaluated.

## Security semantics do not silently weaken

A missing identity, trust root, signer, policy, or required verifier blocks the
protected conclusion or effect. Parsing failure for one evidence type does not
authorize reinterpretation as a weaker type. Request-controlled material may
be compared with a configured trust expectation; it may not define the
authority used to authenticate itself.

Transport location, content identity, and signer authority remain separate.
Moving an artifact through a local registry must not change its digest or the
signer policy used to admit it.

## Semantic equality is explicit

Security decisions must not depend on incidental serialization, storage, or
retrieval representation. Canonical projections normalize only values whose
variation is expected and non-security-bearing. Security-bearing differences
remain visible.

Determinism applies to the bounded analytical or proof projection, not every
timestamp, UUID, signature, log line, or runtime byte. Evaluator identity and
version are evidence when a claim depends on reproducing that evaluator's
decision; TruthFast does not claim universal evaluator provenance.

## Conclusions preserve causes and coverage

A final `PASS`, `FAIL`, `ALLOW`, or `DENY` is a projection, not the complete
causal record. Evidence retains the applicable identity, producer, policy,
operation, source revision, and run identity needed to justify the bounded
claim.

Validator silence is never success. Every mandatory check must reach an
acceptable decision. `FAIL`, `BLOCKED`, and `NOT_EVALUATED` remain distinct,
and a missing mandatory result prevents final `PASS`.

## Authority is bounded in time and scope

Authentication identifies an actor; it does not by itself authorize every act.
Preparation proves admissibility at the preparation point, not permanent
authority to commit after mutable predicates change. Current V1 flows recheck
the state required by their supported effect boundaries; TruthFast does not
claim a general distributed transaction or one-use semantic-authority system.

Service/workload identity, runtime-instance identity, and placement identity
are distinct. V1 proves bounded SPIFFE workload/service identity. It does not
claim that node placement or a stable service identity uniquely identifies one
workload instance.

## Constitutional authority precedes governed state

The bootstrap authority begins outside mutable Kubernetes runtime state: human
authorization, clean source, pinned inputs, host trust, and signing authority
establish the plane that later governs Kubernetes state. Mutable governed state
cannot silently redefine that independent root.

## Ordering and derived views are explicit

Load-bearing sequences use explicit keys, direction, and tie-break behavior;
incidental datastore order is not a contract. Derived views must remain bound
to the source generation or digest needed by the claim, or disclose that they
are a mixed snapshot.

## Current boundaries

TruthFast currently proves successor trust publication, acceptance by
load-bearing Istio/Envoy consumers, and current-lineage convergence. It does not
independently claim behavioral rejection of every retired predecessor at every
relying consumer.

Independent semantic replay and replay/receipt-based certification are
post-V1 research. Declared credential-consumer intent, universal evaluator
provenance, universal structural verifier budgets, capability minimization, and
privilege necessity remain bounded validation or watch topics rather than
implicit V1 guarantees.
