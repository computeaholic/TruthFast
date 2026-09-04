# 17. Concept Index

Purpose: provide the canonical ownership map for TruthFast's first-class architectural concepts.

Owner: Architecture

Boundaries:

- This document names concept owners.
- This document does not redefine contracts owned elsewhere.
- This document does not describe historical evolution.
- This document does not duplicate the lexicon or the proof contract.

Dependencies:

- `docs/Agent-Containment.md`
- `docs/CANONICAL/ENGINEERING_LEXICON.md`
- `docs/CANONICAL/ARCHITECTURE.md`
- `docs/CANONICAL/IDENTITY.md`
- `docs/CANONICAL/TRUST_MODEL.md`
- `docs/CANONICAL/POLICY_ENFORCEMENT.md`
- `docs/CANONICAL/PROOF_MODEL.md`
- `docs/CANONICAL/PROOF_CONTRACT.md`
- `docs/CANONICAL/AUDIT_MODEL.md`
- `docs/CANONICAL/OBSERVABILITY.md`
- `docs/CANONICAL/SECURITY_MODEL.md`
- `docs/CANONICAL/SUPPLY_CHAIN.md`
- `docs/architecture/01-Constitution.md`
- `docs/architecture/07-Certification-Architecture.md`
- `docs/architecture/14-Governance.md`
- `docs/architecture/16-Repository-Information-Model.md`

Forward references:

- `docs/CANONICAL/ENGINEERING_LEXICON.md` for formal vocabulary definitions
- `docs/Agent-Containment.md` for the whole-system thesis
- `docs/CANONICAL/*` for normative contracts
- `docs/architecture/16-Repository-Information-Model.md` for directory and ownership projections

Backward references:

- `README.md`
- `docs/index.md`
- `docs/START_HERE.md`
- `docs/CANONICAL/README.md`
- `docs/architecture/_manifest.md`
- `docs/architecture/repository-manifest.yaml`

## Concept graph

The table below records the canonical owner for each first-class concept. Definitions are intentionally brief; the owning document carries the full contract.

| Concept | Definition | Canonical owner | Primary consumers | Related concepts |
| --- | --- | --- | --- | --- |
| Identity | The authenticated workload or control-plane identity that authority binds to. | `docs/CANONICAL/IDENTITY.md` | admission, runtime, proof | authority, trust, attestation, execution identity, composite identity |
| Execution identity | The identity that is valid for a specific execution context and not merely for a resource name. | `docs/CANONICAL/IDENTITY.md` | runtime enforcement, proof | identity, completion, witness |
| Composite identity | The preserved identity continuity across job, pod, container, and evidence objects. | `docs/CANONICAL/IDENTITY.md` | proof witnesses, replay | execution identity, completion, evidence |
| Authority | The bounded right to decide, publish, admit, or enforce a state transition. | `docs/CANONICAL/TRUST_MODEL.md` | governance, enforcement, proof | trust, governance, publication, decision path |
| Trust | The authoritative chain that makes identity and publication valid. | `docs/CANONICAL/TRUST_MODEL.md` | runtime, proof, certificate lifecycle | authority, attestation, publication, successor root |
| Institutional trust | The repository-level trust relationship that explains why evidence may be certified. | `docs/Agent-Containment.md` | certification, release review | trust, certification, governance |
| Execution | A bounded state transition owned by one producer. | `docs/architecture/06-Proof-Architecture.md` | bootstrap, proof, validation | operation, completion, guarantee |
| Operation | A specific execution with a declared producer, inputs, and terminal state. | `docs/architecture/06-Proof-Architecture.md` | bootstrap, proof, runtime workflows | execution, completion, snapshot |
| Snapshot | A point-in-time witness that establishes preconditions at T0. | `docs/architecture/06-Proof-Architecture.md` | bootstrap, proof witnesses | completion, guarantee, continuity |
| Completion | The identity-bound terminal state of an operation. | `docs/CANONICAL/PROOF_CONTRACT.md` | proof, validation, runtime workflows | execution, evidence, replay |
| Guarantee | A claim about runtime behavior that is only valid when its producer reports the required evidence. | `docs/CANONICAL/PROOF_CONTRACT.md` | proof, certification | completion, evidence, observation |
| Evidence | The runtime or proof output that demonstrates a state transition. | `docs/CANONICAL/AUDIT_MODEL.md` | proof, certification, review | witness, projection, publication |
| Observation | The act of reading a producer's evidence without mutating it. | `docs/CANONICAL/PROOF_MODEL.md` | proof, validation, review | witness, evidence, projection |
| Witness | A consumer that records what it observed and must not own the transition it observes. | `docs/CANONICAL/PROOF_MODEL.md` | proof scripts, validation scripts | observation, evidence, verification |
| Projection | A derived representation of authoritative runtime evidence. | `docs/CANONICAL/PROOF_MODEL.md` | proof publication, navigation, reporting | evidence, replay, determinism |
| Proof | The normalized, source-bound artifact set that explains whether the declared boundary held. | `docs/CANONICAL/PROOF_MODEL.md` | certification, review, validation | evidence, witness, projection, determinism |
| Verification | The act of checking a proof or artifact against its authoritative source. | `docs/CANONICAL/PROOF_CONTRACT.md` | proof scripts, release checks | validation, certification, evidence |
| Validation | The scheduler-driven execution path that discovers the next producer to repair. | `docs/architecture/07-Certification-Architecture.md` | `make validate-all`, release checks | verification, proof, certification |
| Certification | The bounded conclusion a reviewer may draw from validated evidence. | `docs/architecture/07-Certification-Architecture.md` | release readiness, review | validation, acceptance, publication |
| Acceptance | The explicit decision that the evidence is sufficient for the declared boundary. | `docs/architecture/07-Certification-Architecture.md` | release review, governance | certification, publication |
| Publication | The act of making authoritative evidence or contracts available to consumers. | `docs/CANONICAL/PROOF_MODEL.md` | proof publishing, release baseline | evidence, projection, repository manifest |
| Replay | In V1, cryptographic verification and bounded producer-path re-execution that reproduces the same semantic proof projection; independent semantic replay is post-V1. | `docs/CANONICAL/PROOF_MODEL.md` | determinism validation, certification | proof, determinism, evidence |
| Determinism | The property that equivalent inputs yield stable normalized outputs. | `docs/CANONICAL/PROOF_CONTRACT.md` | proof-determinism, release certification | replay, projection, completion |
| Containment | The relationship among identity, provenance, admission, runtime, and evidence. | `docs/Agent-Containment.md` | whitepaper readers, certification reviewers | policy, runtime, trust, proof |
| Policy | The declared enforcement rule that admission and runtime checks apply. | `docs/CANONICAL/POLICY_ENFORCEMENT.md` | admission, witness scripts | boundary, runtime, trust |
| Runtime | The live workload and control-plane environment where evidence is produced. | `docs/CANONICAL/ARCHITECTURE.md` | proof, observability, policy | execution, identity, observability |
| Observability | The evidence plane for metrics, logs, traces, and audit visibility. | `docs/CANONICAL/OBSERVABILITY.md` | proof, certification, operations | evidence, replay, publication |
| Supply chain | The digest, signing, registry, and provenance chain for executable artifacts. | `docs/CANONICAL/SUPPLY_CHAIN.md` | bootstrap, proof, runtime deployment | publication, trust, runtime |
| Attestation | The proof-backed assertion that an identity or artifact is valid. | `docs/CANONICAL/IDENTITY.md` | SPIRE, runtime identity, trust | identity, trust, publication |
| Topology | The documented relationship among directories, owners, and navigation surfaces. | `docs/architecture/16-Repository-Information-Model.md` | documentation, validation, repository governance | boundary, governance, publication |
| Boundary | The explicit line that separates a producer's authority from a consumer's observation. | `docs/CANONICAL/SECURITY_MODEL.md` | enforcement, proof, red-team review | containment, policy, trust |
| Governance | The rules that bound architectural change, break-glass, and release authority. | `docs/architecture/14-Governance.md` | maintainers, certification, release | authority, acceptance, publication |
| Decision path | The sequence that explains how a conclusion was reached from evidence. | `docs/CANONICAL/AUDIT_MODEL.md` | proof review, hostile review, certification | witness, evidence, replay |

## Concept ownership rules

1. The owner listed in this index is the primary canonical source for the concept.
2. Supporting documents may reference the concept, but they do not redefine it.
3. Historical documents may explain how the concept evolved, but they do not own it.
4. Consumers must link back to the owner rather than restating the definition.
5. If a new document duplicates a concept definition, the duplicate is a drift defect.

## Reading order

1. `README.md`
2. `docs/START_HERE.md`
3. `docs/Agent-Containment.md`
4. `docs/architecture/16-Repository-Information-Model.md`
5. `docs/architecture/17-Concept-Index.md`
6. `docs/CANONICAL/README.md`
7. Canonical contract documents
