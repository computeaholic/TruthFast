# ThreadForge Failed-Assumption Doctrine, 2026-08-28

## Record Boundary

This record preserves the complete A-AI failed-assumption doctrine supplied to
the 2026-08-28 review and its ThreadForge adjudication. The doctrine is research
input, not constitutional authority. The descriptive machine mapping is
`docs/architecture/system-model/research_doctrine_matrix.json`; actionable
project work remains owned by `project_obligations.json`.

- Repository review SHA: `9ce19c9dfbf7583d7cb29a0c8cef388ab194ee1a`
- Runtime-qualified SHA considered: `b7e8612b94089dd574d7064d709427add22dbd51`
- Laws reviewed: `35`
- Validated strengths: `16`
- Architectural alignments: `12`
- Validation incomplete: `3`
- Gaps identified: `0`
- Post-V1: `2`
- Watch items: `2`

Each section first preserves the supplied doctrine, then records the bounded V1
mapping. “Validated strength” applies only to the named ThreadForge surface; it
does not claim the principle universally.

## Law A - Semantic Equality Is Not Representational Equality

Equivalent logical state may arrive through different representations.
Kubernetes CEL demonstrated that cache and retrieval paths can produce
representation differences that affect evaluation. Canonical evaluation must
therefore satisfy `semantic_input_equal -> decision_equal` without discarding
the exact consumed representation when it matters diagnostically.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). Proof
normalization distinguishes expected non-security-bearing variation from
security-bearing differences. This is established for the canonical proof
projection, not every possible evaluator or object representation.

## Law B - Observed Operation Result Is Not Authoritative State

A remote mutation may succeed while the client observes failure. Distinguish
the command result, authoritative post-state, intended postcondition, and
convergence result. Execute, observe authoritative state, classify the outcome
as applied, not applied, or ambiguous, and retry only under idempotent rules.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Bootstrap and
convergence producers observe their owned state and use bounded convergence;
they do not derive runtime truth from one client exit alone.

## Law C - Final Disposition Is Not Sufficient Evidence

ALLOW or DENY is a projection. Multiple policy failures may collapse to the
same visible result. Where the claim depends on cause, evidence should preserve
evaluators, policy and binding identities, expression or condition context,
evidence consumed, short-circuit behavior, complete failure information, and
the final disposition. Identical terminal results reached by different causal
paths should remain distinguishable.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). Proof and
audit preserve named guarantees, owners, operation identity, evidence, and
failure classes. ThreadForge does not claim a universal complete policy trace
for every upstream engine.

## Law D - Identity Authenticates the Actor; Request Binding Authenticates the Act

Valid workload identity does not prove authorization of an exact action.
Privileged operation evidence may need to bind the actor, workload instance,
action, target, artifact digest, policy generation, trust epoch, audience,
nonce, action digest, and time bounds. Only fields relevant to the supported
authority surface should be required.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). Supported
API and policy paths bind authenticated workload identity to scoped operations
and targets. V1 does not claim a generic signed request-envelope protocol.

## Law E - Credential Issuance Requires Declared Intent

Identity existence is not credential eligibility. A credential request should
map to an immutable workload, declared credential consumer, signer and trust
domain, authorized issuance path, and issuance evidence.

**ThreadForge mapping:** `VALIDATION_INCOMPLETE` (medium confidence). SPIRE
registration and Kubernetes selectors bound issuance, but V1 does not separately
claim or prove a declared credential-consumer intent object. This is a bounded
evidence pressure, not a discovered V1 defect.

## Law F - Consumer Convergence Is Stronger Than Producer Convergence

For a load-bearing distributed property, the proof chain is desired state,
authoritative producer state, derived state, distribution, consumer receipt or
state, and effective enforcement. A producer reporting an update or a
controller reporting green is insufficient. The security property exists where
load-bearing consumer behavior establishes it.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Qualification
follows SPIRE authority through Istio and Envoy and exercises admission,
authorization, and network behavior at consumers.

## Law G - Determinism Includes the Evaluator

The same policy source does not imply the same decision. The decision function
may include policy, engine and version, execution mode, canonical context,
feature state, external dependencies, and registry or trust state. Evaluator
identity, version, and configuration belong in evidence when reproduction of
that decision depends on them.

**ThreadForge mapping:** `VALIDATION_INCOMPLETE` (medium confidence). V1 proves
source binding and stable semantic proof projections, but makes no universal
evaluator-version provenance claim for every decision engine.

## Law H - Authority Provenance Is Part of Provenance

A valid artifact signature alone does not establish legitimate provenance.
Relevant distinctions may include artifact digest, producer identity, signer
identity and epoch, signing authority, credential or key issuance, signing
event, transparency evidence, policy generation, and verification result.
Proof itself has a trust history.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Supply-chain
and audit evidence retain distinct artifact, signer, key-registry, policy,
source, and verification boundaries.

## Law I - Security Decisions Require Causal Context

A locally valid decision can be globally wrong without runtime relationships.
A deterministic decision over incomplete context can be reproducibly wrong.
Relevant context may include target, dependencies, identity and policy bindings,
trust domain, runtime consumers, evidence dependencies, and snapshot digest.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). Evidence
contracts and the system model preserve the relationships required by bounded
claims; ThreadForge does not claim a universal causal model.

## Law J - Valid Transitions Do Not Imply a Valid Transaction

Every local edge of a workflow may be authorized while the whole causal
sequence remains forbidden. A valid producer-to-validator, validator-to-signer,
or signer-to-publisher transition does not by itself prove a valid transaction.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). Operation
Contracts bind preconditions, execution, completion, guarantees, evidence, and
certification while explicitly declining ACID or general distributed
transaction semantics.

## Law K - Semantic Authority Must Be Consumed Durably

Replay resistance is not token uniqueness. Attempt identity, proof identity,
authorization identity, semantic action digest, and effect identity may be
distinct. A fresh token must not reactivate already-consumed semantic authority.
Distributed effect authority requires durable shared consumption state.

**ThreadForge mapping:** `POST_V1` (high confidence). V1 does not expose a
supported distributed one-use semantic-authority claim. Independent semantic
replay remains issue 550 and conditional certification migration remains issue
554.

## Law L - Idempotency Belongs at the Effect Boundary

A lost response after a successful effect must not permit duplicate external
consequence. The ambiguous path is authorize, prepare, mutate successfully,
lose the response, crash, retry, then reconcile authoritative post-state rather
than blindly repeat. This does not require a generic transaction system.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). Supported
convergence producers re-observe owned post-state before bounded retries. V1
makes no general external-effect idempotency claim.

## Law M - Trust Semantics Cannot Be Recovered by Reinterpretation

If parsing a value declared as trust-evidence type A fails, the same
attacker-controlled bytes must not be reinterpreted as trust type B and sent to
a weaker or different verifier. Declared evidence parsing failure is explicit
failure. Claimant-controlled evidence may not replace a configured trust root,
key, issuer, or verifier.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). The targeted
trust-semantic downgrade audit found no cross-type trust fallback in current
certificate, bundle, identity, or signature paths.

## Law N - Lifecycle Validity Is Part of Identity

A cryptographically valid credential is not necessarily a current workload
instance or an authorized action. Service identity, runtime instance identity,
and placement identity remain distinct. Historical authentication can remain
valid historical evidence while carrying no current authority.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Authority
defaults to `UNCLAIMED`, requires currently validated SPIRE identity, and has no
synthetic signing-key identity fallback. V1 claims workload/service identity,
not unique instance identity.

## Law O - Observability Is Not Automatically Proof

Telemetry traverses a hook, filters, buffers, collector, transport, storage,
and query; each edge may lose state. For load-bearing telemetry the relevant
completeness property is undetected loss equal to zero, not necessarily loss
equal to zero. Capture boundary, coverage, ordering, loss detection, tamper,
restart, buffer, time, identity, and authoritative versus corroborative role
bound what the source can prove. Absence can establish absence only when
failure to capture is itself detectable for the bounded claim.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). Metrics,
logs, and traces are bounded evidence sources; no potentially lossy telemetry
source alone establishes a completeness claim.

## Law P - Preparation Proves Historical Admissibility, Not Current Committability

A candidate valid at prepare time can become unsafe before activation. The
required reasoning is prepared-valid-at-T0, commit-time revalidation, then
committable-now or stale-reprepare. Mutable predicates include trust roots,
signers, policy generation, artifact digest, dependencies, identity, and time.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). The
targeted prepare/commit review found no confirmed V1 gap in supported trust and
publication flows; it did not establish a universal transaction property.

## Law Q - Mandatory Mediation Must Be Proven

Configured routing through an enforcement boundary does not prove mandatory
traversal. For a protected effect, enumerate reachable paths and prove each
crosses the boundary and cannot be bypassed by an equally authorized identity
or topology. Policy existence is not mandatory mediation.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Supported
admission, north-south, east-west, identity, and registry/signature boundaries
include direct negative bypass specimens.

## Law R - Verifier Complexity Is Part of the Trust Boundary

Syntactically bounded untrusted evidence can still induce disproportionate
verification work. Structural budgets may limit certificate count, chain
depth, candidate parents, nesting, policy nodes, decompressed bytes, external
resolution, and verification operations. Timeout alone is not always a complete
structural defense; resource-limit and verifier-failure outcomes may need to
remain distinct.

**ThreadForge mapping:** `VALIDATION_INCOMPLETE` (medium confidence). Current
verifiers use bounded inputs and timeouts where implemented, but V1 makes no
universal structural-budget claim and no concrete exploitable V1 path was found.

## Law S - Consumed Context Is Evidence

State existing in a global store does not prove it participated in a specific
decision. Where a decision depends on shared context, evidence should identify
the context actually loaded, including source, version, content digest, and its
use in that evaluation. This principle does not require a new receipt schema.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (medium confidence). Bounded
proof and CIV decisions retain relevant source, digest, policy, or operation
context, without claiming universal consumed-context receipts.

## Law T - Security Scope Must Be Explicit

Namespaced resources, Namespace objects, and cluster-scoped resources have
different semantics. An empty namespace coordinate is not automatically
neutral. Security decisions must not infer scope from ambiguous absence.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Namespace
contracts, RBAC, SPIFFE selectors, and policy verifiers use explicit scope on
load-bearing V1 paths.

## Law U - Evidence Status Is Not Evidence

Words such as verified, anchored, certified, and timestamped are projections.
A verifier must reconstruct the exact bounded claim. Artifact integrity,
producer identity, authorization validity, policy compliance, checkpoint time,
event order, and execution reproducibility are distinct claims; one
`verified=true` must not collapse them.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Proof
guarantees, signatures, source binding, audit, and certification are separate
surfaces with bounded meanings.

## Law V - Displayed Metadata Is Not a Cryptographically Bound Claim

A displayed timestamp, status, or log field is not cryptographically proved
unless evidence commits it. Keep distinct what is displayed, what is recorded,
and what is cryptographically bound.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Qualification
records distinguish operator metadata, source/run identity, and signed proof
content; they do not claim every displayed field is signed.

## Law W - Every Derived View Must Be Bound to Its Source State

Git manifests, parsed and normalized manifests, API objects, caches, policy
inputs, XDS state, audit events, and proof records can refer to different
generations. A load-bearing derived view should preserve source digest or
generation, derivation identity, and content digest, or disclose a mixed
snapshot. The critical failure is a conclusion assembled from incompatible
generations while claiming one coherent state.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). Source
SHA, object UID, owner references, artifact digests, and runtime imageID bind
the views needed by supported claims. ThreadForge does not claim a universal
snapshot protocol.

## Law X - Required Security Must Not Degrade Implicitly

Unavailable required security is not weaker security. Missing mTLS, policy,
trusted signer, identity, or verifier must produce explicit failure, blocked,
or indeterminate state and forbid the protected effect. It must not silently
select plaintext, permissive policy, a weaker signer, or anonymous authority.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Identity,
policy, trust, supply-chain, and proof paths fail closed without implicit weaker
fallback.

## Law Y - Authorizer and Effect Handler Must Share One Canonical Action

An authorizer must not approve one semantic action while an effect handler
executes another representation. Applicable fields include normalized path,
encoded separators, target, artifact and body digest, operation, audience,
host, and mutable request fields. Evidence must describe the same action.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (medium confidence). The
targeted current-surface review found no confirmed V1 mismatch. This does not
create an independent semantic replay claim.

## Law Z - Constitutional Authority Must Precede Governed State

Security controls cannot bootstrap solely from mutable state inside the plane
they govern. An independently established constitutional root protects policy
authority, which protects mutable runtime state; mutable runtime state must not
be the sole authority protecting itself.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Human
authorization, clean source, pinned inputs, host trust, and signing authority
precede Kubernetes state, which cannot silently redefine that root.

## Law AA - Revocation Completes at the Relying Party

A source-of-truth update does not prove old authority is revoked. A trust-root
transition is root N active, successor published, consumers accept N+1,
consumers reject N, then N is retired. Strong behavioral proof is old authority
rejected and new authority accepted at every required consumer. Configuration
replacement is not behavioral rejection evidence.

**ThreadForge mapping:** `ARCHITECTURAL_ALIGNMENT` (high confidence). V1 proves
successor publication, acceptance by load-bearing Istio and Envoy consumers,
and current-lineage convergence. It does not independently claim rejection of
every retired predecessor at every relying consumer.

## Law AB - Placement Is Not Identity

Node or host placement identifies topology, not a unique runtime actor. Service
or group identity, runtime instance identity, and placement identity remain
distinct. A replacement workload should not inherit instance-specific authority
merely because its service account, namespace, or node is unchanged.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). V1 proves
bounded SPIFFE workload/service identity and does not claim placement or stable
service identity as unique runtime-instance authority.

## Law AC - Capability Absence Is Stronger Than Denied Capability

For a role that should never perform a privileged operation, absence of the
surface is stronger than an available surface expected to be denied. Unneeded
Workload API, SDS, kubelet, mutation, or credential capabilities should be
removed when that need is independently established; denied capability is not
automatically a defect.

**ThreadForge mapping:** `WATCH_ITEM` (medium confidence). Important surfaces
are default-deny or unsupported where applicable, but V1 makes no universal
capability-minimality claim and the review found no obvious low-cost removal
whose necessity was independently proven.

## Law AD - Event Ordering Must Be Explicit

Datastore natural ordering is not a contract. Authoritative audit, replay, and
event consumers need explicit ordering keys, direction, tie-breaks, cursors,
and query/version semantics where relevant.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Load-bearing
current audit, lifecycle, and proof ordering uses explicit sequence or ordering
keys; the targeted review found no authoritative V1 sequence relying on
incidental storage order.

## Law AE - Replay Protection Is Only as Global as Durable Consumption State

A local replay cache does not establish global consumption:
`seen_by_replica_A != consumed_globally`. Distributed semantic authority needs
shared durable consumption state.

**ThreadForge mapping:** `POST_V1` (high confidence). V1 makes no supported
distributed one-use authority or independent semantic replay claim. Issues 550
and 554 retain that research boundary.

## Law AF - A Request Cannot Define Its Own Trust Context

Audience, trust domain, authority, signer, issuer, and verifier expectations
must derive from independently trusted configuration or policy. Host, forwarded
host, issuer, audience, registry, signer, and trust-domain hints from a claimant
may be compared with that authority but cannot select it.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). SPIFFE trust,
proxy-produced XFCC with `SANITIZE_SET`, registry signer policy, and the
`UNCLAIMED` authority default derive from trusted configuration rather than raw
request material.

## Law AG - Transport Location, Content Identity, and Signer Authority Are Different Claims

Artifact retrieval location, artifact identity, and signer authority are
distinct. Registry or mirror migration can change transport location but must
not silently alter digest, acceptable signer or epoch, release identity, or
verification policy.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Canonical image
inventory, digest pinning, Cosign policy, runtime imageID reconciliation, and
registry drift proof preserve this separation; no transport fallback weakens
content or signer authority.

## Law AH - Declared Privilege Is Not Evidence of Necessity

A manifest states what privilege a workload possesses, not what it requires.
Static inspection, runtime observation, and capability inference may suggest a
reduction, but enforcement should change only after independent validation.

**ThreadForge mapping:** `WATCH_ITEM` (medium confidence). V1 proves bounded
permission and denial contracts but does not claim universal privilege
necessity or minimality. No permission was removed solely because it appeared
unused.

## Law AI - Security Silence Is Not Success

High correctness among completed decisions can hide poor decision coverage. A
security validator must not reduce PASS, FAIL, unsupported, indeterminate,
malformed, resource-limit, verifier-error, and dependency-unavailable outcomes
to “all checks that returned a result passed.” Certification requires complete
mandatory-check coverage and acceptable PASS decisions for every required
check.

**ThreadForge mapping:** `VALIDATED_STRENGTH` (high confidence). Validate-all
and proof aggregation preserve `FAIL`, `BLOCKED`, and `NOT_EVALUATED`; missing
required phases or guarantees prevent final PASS. The qualified evidence
contains 28 of 28 guarantees with no unevaluated guarantee.

## Consolidated Boundaries

The three `VALIDATION_INCOMPLETE` classifications are E (declared issuance
intent), G (universal evaluator/version provenance), and R (universal
structural verifier budgets). They are bounded proof pressure, not known V1
defects or implicit support obligations.

The two `POST_V1` classifications are K and AE. Independent semantic replay and
replay/receipt-driven certification remain explicitly outside current V1.

The two `WATCH_ITEM` classifications are AC and AH. Capability minimization and
privilege necessity require evidence before removal; neither is a current
universal V1 claim.

No law in this review produced a new current V1 implementation gap.
