# TruthFast: Constitutional Assurance for Identity-Bound Consequential Execution

> **Status:** authoritative architectural thesis
>
> **Scope:** the whole-system argument for TruthFast; precise contracts live in the canonical documents under `docs/architecture/*` and `docs/CANONICAL/*`.

## Release provenance

The stable public file anchor for this paper is `v1.0.0` in the
`computeaholic/TruthFast` repository. The qualified engineering source revision
is `0ddae102badf2a93fe4fdb3934ad9a36db4c8c84`, from the private ThreadForge
engineering lineage. These identities are intentionally distinct; this paper
does not claim independent validation or production certification.

## Abstract

Institutions increasingly permit software to initiate consequential work. The
software may be a deployment controller, remediation system, policy-driven
operator, or autonomous agent; the accountability problem is the same. After an
operation changes a system, the institution must be able to establish what ran,
under whose authority, whether that operation completed, which guarantees held,
and what conclusion the evidence justifies.

Existing controls provide essential but bounded answers. Identity authenticates
a subject. Policy evaluates a request. Supply-chain controls establish an
artifact. Runtime controls constrain behavior. Observability records signals.
None independently defines the conclusion that joins those answers across one
execution.

TruthFast is a constitutional assurance architecture for that conclusion. It
defines claims independently of their providers, binds runtime claims to an
identity-bearing Operation Contract, requires evidence from the producers that
own the relevant state transitions, and limits certification to what
deterministic proof supports. Its native Kubernetes reference implementation
demonstrates one bounded realization. The architecture does not eliminate trust
in that implementation; it makes the trusted boundary explicit and prevents the
originating platform's own status assertion from serving as proof.

TruthFast's constitutional scope is bounded assurance over identity-bound
consequential execution. Autonomous containment is a major demonstrated
application, not the whole constitution.

The native implementation's center of gravity is the chain from source-defined
intent, through producer-owned convergence and authoritative runtime state, to
identity and enforcement, deliberate positive and negative behavior,
observation, non-healing assurance, integrity-bound evidence, and exact-SHA
qualification. OperatorCore, CIV, the optional API, and CI are supporting or
secondary surfaces; none is the mandatory V1 system kernel.

## The institutional problem

Delegating execution does not delegate accountability. An automated system can
select an artifact, acquire identity, cross trust boundaries, invoke services,
mutate state, and trigger later work. The organization remains responsible for
the result even when no person approved each intermediate action.

Component security does not resolve that responsibility. A signed image says
nothing about its runtime network path. Admission says nothing about an
already-running workload. A healthy service mesh says nothing about artifact
provenance. A denial does not show whether policy rejected the request or an
unavailable webhook happened to block it. A log records an event but does not,
by itself, establish which conclusion that event supports.

The missing object is not another control. It is the justified institutional
conclusion about a specific execution.

## Why existing systems are not wrong

TruthFast depends on specialized systems precisely because they answer their
local questions well. The architectural gap appears only when those answers
must support one cross-system conclusion.

| System boundary | Question it answers |
| --- | --- |
| Identity | Who is this? |
| Artifact provenance | What executable artifact was established? |
| Policy and admission | May this request begin? |
| Runtime enforcement | Which behavior and communication paths are permitted? |
| Observability and audit | What did the platform record? |
| TruthFast assurance | What conclusion is justified about this identity-bound operation? |

TruthFast does not replace the systems above. It composes their bounded
results under explicit ownership, evidence, and certification rules. Their
local authority remains local; no component is asked to prove what it cannot
observe.

## The constitutional thesis

TruthFast treats an assurance conclusion as a governed security object. A
conclusion may be published only when it traces to a declared claim, a specific
operation, producer-owned evidence, deterministic proof, and a certification
policy that bounds its meaning.

> The unit of assurance is not the component. It is the justified conclusion
> about an identity-bound operation.

That sentence is the architecture. Everything else preserves its validity.

A producer alone owns a state transition. Consumers may depend on it but may not
recreate its semantics. Witnesses observe and report; they do not repair what
they evaluate. Projections are derived for consumption and never become
parallel authority. If validation heals the runtime, proof reclassifies a
failure, or a generated report is edited as truth, the conclusion has separated
from its source.

The [Engineering Lexicon](CANONICAL/ENGINEERING_LEXICON.md) owns the formal
definitions. This paper owns the architectural relationship among them.

## The assurance relationship

TruthFast separates stable institutional meaning from replaceable execution
mechanics:

```text
CONSTITUTION
Capability -> Claim
                |-> defines Guarantees
                |-> requires Evidence Contract
                `-> selected by Certification Policy

IMPLEMENTATION
Profile -> Provider -> Producer (owns Execution and Evidence)

OPERATION
Operation Identity -> Preconditions -> Execution -> Completion
                                      |              |
                                      `-> Guarantees-'
                                              |
                                              v
                                     Runtime Evidence
                                              |
                                   conforms to Evidence Contract
                                              |
                                              v
                                            Proof
                                              |
                                evaluated by Certification Policy
                                              |
                                              v
                                Bounded Institutional Conclusion
```

The constitution states what must be established. Capabilities group assurance
responsibilities; claims state invariants and failure semantics; Evidence
Contracts define the producer-evaluator boundary; Certification Policies define
what is sufficient for a scoped conclusion. These objects are stable and
versioned.

Profiles, providers, collectors, evaluators, scripts, and runtime controls are
implementation. They realize constitutional objects but cannot redefine them.
This direction of authority is what keeps an implementation limitation from
quietly becoming a weaker institutional claim. The
[Constitution](architecture/01-Constitution.md) and
[assurance reference architecture](architecture/00-ThreadForge-Assurance-Reference-Architecture.md)
own the formal dependency rules.

## The Operation Contract

Claims become reviewable only when attached to one execution. The Operation
Contract is the model that performs that binding. It is analogous in role to a
transaction model: it gives a unit of work an identity, admissibility
conditions, an execution owner, a terminal state, invariants, and a durable
record. It is not an independent claim authority, does not imply ACID semantics,
and does not coordinate distributed transactions.

Its sequence is:

> Operation Identity -> Preconditions -> Execution -> Completion -> Guarantees
> -> Evidence -> Certification

Operation Identity distinguishes this run from earlier, concurrent, or recreated
runs. Preconditions establish whether it may begin. One producer owns execution.
Completion follows identity and ownership to the terminal state. Guarantees
describe what must hold during execution or at completion. Evidence records the
result. Certification interprets validated proof under policy.

The distinctions prevent observations from acquiring meaning they do not have.
A ready control plane may permit an operation to begin; it does not prove that
the control plane remained available until completion. A Kubernetes Job name
may locate objects; it does not establish that an observed Pod belongs to this
Job execution. A timeout establishes that a transition missed its bound; it
does not identify the producer or the cause.

Authority must be carried by identity, never reconstructed from discovery.
Completion, guarantees, and evidence preserve that identity chain through the
operation.

## Claims outlive providers

Provider independence is not an extension mechanism. It is how assurance
survives implementation change.

Replacing an identity provider, policy engine, registry, or observability stack
changes how evidence is produced. It must not change what identity continuity,
artifact integrity, or policy enforcement means to the institution. The
Evidence Contract preserves what the evaluator requires. The claim preserves
the invariant. The Certification Policy preserves the threshold for acceptance.

Provider replacement therefore becomes an implementation concern rather than
an assurance redesign. That separation is conditional: a replacement must
produce conformant evidence, preserve required continuity, and satisfy the same
failure semantics. A provider that cannot establish a claim must fail or declare
the claim unsupported. It may not weaken the claim until its output passes.

TruthFast defines this boundary. It does not claim that provider replacement
is migration-free or that every possible provider and platform profile has
already been implemented or certified.

> Providers may change. Runtime values may vary. The assurance relationship must
> remain intact.

## Authority requires identity and restraint

An operation cannot carry authority by name alone. Names, labels, and placement
are mutable and reusable. TruthFast binds runtime authority to authenticated
workload identity and binds evidence to operation and object identity wherever
one execution must be distinguished from another.

Identity does not grant unlimited authority. Authority is a bounded right to
decide, publish, admit, or enforce a transition. It may be scoped, delegated,
expired, or revoked. Trust is the chain that makes identity and authority
acceptable to their consumers.

Autonomy does not collapse decision and execution authority. Autonomous agents
are one application domain, not the constitutional unit. The repository's
[Civ intelligence surfaces](https://github.com/computeaholic/TruthFast/blob/v1.0.0/platform/runtime/civ/README.md) produce
deterministic, non-binding advisory artifacts and are mechanically prohibited
from enforcement. An external authority decides whether an operation may
proceed. A recommendation is input to governance, not permission to execute.

In the native implementation, SPIFFE identities issued through SPIRE identify
workloads. SPIRE owns the trust authority, and the Istio certificate path is
rooted in that authority. Active authority, issuance authority, and bundle
membership remain distinct during legitimate rollover; the selected runtime
lineage must remain coherent across SPIRE, Istio, and Envoy. Missing or
inconsistent trust state fails the relevant contract rather than activating an
undeclared fallback. The
[identity](CANONICAL/IDENTITY.md) and [trust](CANONICAL/TRUST_MODEL.md) documents
own the implementation mechanics.

The qualified lifecycle evidence follows successor publication into
load-bearing Istio/Envoy consumers and establishes acceptance of the current
lineage. It does not independently claim that every relying consumer
behaviorally rejects every retired predecessor. That stronger revocation
property remains outside the V1 conclusion.

## Evidence becomes proof

Logs, metrics, traces, and audit records are observations. They become evidence
when they are attributable, contract-relevant, and capable of supporting a
specific claim. Proof is the controlled transformation from that evidence to an
evaluated claim. Certification Evidence is the validated proof material accepted
by a Certification Policy.

Evidence must be independent of the assertion it supports. In TruthFast,
independence means that a runtime producer or observable system creates the
evidence and proof consumes it. It does not mean independent institutional
custody or external anchoring. A signature binds an artifact to a key; it does
not prove that a compromised producer reported a true event. Producer integrity
and signing-key custody remain part of the trusted computing base.

Witnesses may not heal the runtime, reinterpret a failed producer as success, or
infer an unexecuted guarantee from another phase. A synthetic stack probe cannot
substitute for required application telemetry. An unavailable webhook cannot
substitute for evidence that a policy evaluated and denied a request. Proof is
credible only when it remains a consumer.

Determinism applies to the canonical projection, not to every byte of a live
distributed system. Timestamps, object identifiers, scheduling, and trace IDs
may vary without changing a claim. TruthFast retains runtime evidence and
normalizes only values whose variation is expected and not security-bearing.
Equivalent inputs and state must produce identical canonical proof artifacts;
security-relevant differences remain visible.

This evidence includes evaluator identity or version where a current producer
publishes it and a claim consumes it. TruthFast does not make a universal
claim that every external engine version, feature state, or structural
verification budget is captured. Those are explicit boundaries, not values
inferred from a final `PASS`.

Failure also remains evidence. A failed guarantee is `FAIL`; a guarantee that
did not execute because a dependency failed is `NOT_EVALUATED`. Missing
prerequisites, policy violations, contract violations, and system regressions
remain distinct because each permits a different conclusion. The
[Evidence Contracts](architecture/05-Evidence-Contracts.md),
[Proof Model](CANONICAL/PROOF_MODEL.md), and
[Proof Contract](CANONICAL/PROOF_CONTRACT.md) own the exact semantics.

## One native realization

The Kubernetes reference implementation demonstrates a constitutional binding.
It is not the architecture itself.

Its registry, digest, and signature controls establish the artifact path.
Admission evaluates workload identity, provenance, and policy before execution.
SPIRE and SPIFFE establish workload identity and trust. Istio authorization and
network policy constrain runtime communication. Observability and audit produce
queryable evidence. The proof graph evaluates focused witnesses, binds
completion to operation identity, freezes canonical artifacts, and verifies
their integrity and determinism.

Each control remains within its claim. A signed image may still violate runtime
policy. An admitted workload still requires runtime authorization. A fail-closed
webhook timeout blocks admission but does not prove that a specific policy
executed. A manifest may declare isolation; only observed behavior can support
the runtime conclusion.

The executable surface is layered. `make validate-all` is the canonical runtime
authority. `make golden-boot` is the destructive reconstruction path. `make
demo-all` is the supported reviewer aggregate. `make audit` is the operator
diagnostic audit. `make forgesec` is the canonical ForgeSec surface. Narrower
witnesses remain available for focused checks: `make proof`,
`make proof-determinism`, `make prove-active`, and the explicit opt-in
`make prove-spire-outage` assurance witness. They do not replace the broader
claims above, and their success reports only the claims defined by their
contracts. `make prove-spire-outage` is not an ordinary proof phase: it first
demonstrates that normal authority is policy-blocked, then requires an explicit
audited break-glass authority before inducing a real SPIRE outage. The canonical
[architecture](CANONICAL/ARCHITECTURE.md),
[security model](CANONICAL/SECURITY_MODEL.md),
[policy contract](CANONICAL/POLICY_ENFORCEMENT.md), and
[supply-chain model](CANONICAL/SUPPLY_CHAIN.md) own the exact native scope.

## Current reference implementation evidence

The current evidence for the native reference implementation is bound to the
runtime-qualified source revision recorded in
[docs/releases/CERTIFICATION_BASELINE.md](releases/CERTIFICATION_BASELINE.md).
That baseline records the demonstrated native Kind runtime, the supported
reviewer aggregate, the operator audit surface, and the canonical ForgeSec
execution surface. Documentation-only revisions may move repository HEAD
forward without changing that runtime qualification.

The qualified native execution demonstrated destructive reconstruction,
canonical validation, workload identity and trust enforcement, supply-chain
enforcement, deterministic proof contracts, fail-closed behavior,
collector-mediated observability evidence, ForgeSec enforcement, all four
supported reviewer demonstrations, source-clean demo execution, and operator
audit execution. These are bounded internal reference-system results, not
production-readiness, general portability, or independent-validation claims.

## Adjudicated evidence boundaries

The following claims are intentionally narrower than a general outage or
cryptographic-certification claim:

- An authorized-outage witness may claim that, under the explicit audited
  break-glass path, an existing session fails closed after SVID expiry, a fresh
  identity-dependent request fails during real SPIRE unavailability, and the
  restored SPIRE path reconverges before an allowed request succeeds. Normal
  authority remains policy-blocked. This is a bounded Level 2 assurance claim,
  not universal availability evidence.
- The proof tamper witness operates on an isolated copy: a valid copied proof
  tree passes, a tampered copy is rejected, and the canonical proof tree remains
  unchanged. This is artifact-integrity evidence and does not claim external
  anchoring.
- CIV `provenance_hash` is deterministic for equivalent analytical inputs while
  operation identifiers and timestamps remain distinct. Decision records remain
  `ADVISORY_ONLY` with `enforcement_prohibited=true`; this is not byte-level
  determinism for the complete record.
- A source SHA binds an evidence set to the executable repository revision. Run
  IDs identify individual executions and must not be presented as if one run
  were the whole qualification.
- Replayability in the V1 claim means deterministic verification and bounded
  producer-path re-execution under the declared contracts. Independent semantic
  replay by a separately owned decision implementation is post-V1 research and
  is not claimed by the current certification path.

These claims require evidence from the exact source revision being qualified.
The certification baseline remains the authority for the currently graduated
runtime revision.

## Certification creates institutional meaning

Proof establishes what the evidence supports. Certification governs what the
institution may conclude.

A passing proof is necessary evidence for certification; it is not itself a
certification. Certification requires a policy that selects claims, defines
acceptance and freshness, and emits a scoped artifact with provenance to its
supporting proof. For claims named in that artifact, a reviewer may determine
which operation ran, which guarantees were evaluated, which evidence satisfied
their contracts, and which integrity and determinism properties held.

Independence does not mean trusting nothing. An external reviewer need not
accept the originating platform's success message, but must evaluate the
declared trusted computing base and verify the evidence chain. TruthFast makes
that dependence explicit rather than hiding it behind a status line.

Institutional trust also depends on governance. Architectural authority,
implementation authority, runtime authority, exceptional authority, and
certification authority remain separate. Implementations cannot silently
redefine claims. Provider replacements remain subject to constitutional
contracts. Break-glass and administrative paths remain authority paths, not
invisible exceptions.

No conclusion may carry more authority than its claim, operation, evidence,
proof, and governance permit. The
[Certification Architecture](architecture/07-Certification-Architecture.md),
[Governance](architecture/14-Governance.md), and
[certification baseline](releases/CERTIFICATION_BASELINE.md) define the model
and current release boundary.

## Threat boundary and non-claims

The native implementation addresses adversaries and failures below the
Kubernetes cluster-administrator boundary. Its proof exercises unauthorized
workload admission, unsigned or externally sourced artifacts, identity and trust
divergence, sidecar and policy bypass, unauthorized network paths, control-plane
unavailability, and proof-artifact tampering.

Its trusted computing base includes the qualified repository revision and proof
implementation, the Kubernetes API and node boundary, the declared trust root,
signing-key custody, and the integrity of evidence producers. A principal with
cluster-administrator or host-root authority can alter those controls.
TruthFast makes actions through its declared administrative paths
attributable; it does not claim to constrain every use of authority above its
enforcement boundary.

TruthFast does not claim to:

- establish that autonomous intent is correct or beneficial;
- defeat a cluster administrator, node root, or compromised host;
- control an external authority outside the declared trust boundary;
- externally anchor evidence that it does not publish to an external authority;
- eliminate all Kubernetes, supply-chain, application, or network risk;
- prove universal availability or future safety from one passing run;
- provide comparative evaluation, production-scale performance results, or
  high-availability certification;
- demonstrate that every constitutional provider or platform profile has been
  implemented or certified; or
- replace operational ownership, incident response, or independent audit.

The native implementation is evidence for one bounded realization. The
constitutional model defines how other realizations must state claims and
produce evidence; it is not proof that those realizations already exist.

## Review path

A reviewer can follow the active authority chain without reading historical
convergence material:

1. Read the [README](https://github.com/computeaholic/TruthFast/blob/v1.0.0/README.md) and [Start Here](START_HERE.md) for execution
   scope.
2. Read this paper for the architectural thesis.
3. Read the [assurance reference architecture](architecture/00-ThreadForge-Assurance-Reference-Architecture.md),
   [Constitution](architecture/01-Constitution.md), and
   [Concept Index](architecture/17-Concept-Index.md) for ownership.
4. Read the relevant claim, evidence, proof, identity, trust, policy, and
   certification contracts.
5. Inspect the native execution entry points (`make validate-all`,
   `make golden-boot`, `make demo-all`, `make audit`, `make forgesec`) and
   their published artifacts.

Traceability must work in both directions: architecture to implementation to
validation to evidence, and evidence back through witness and producer to the
architectural claim. Historical investigations explain how the repository
evolved; they do not participate in the active authority chain.

## Conclusion

Component controls secure their bounded domains. TruthFast governs the
conclusion an institution may draw about their combined behavior during
identity-bound consequential execution.

That conclusion remains credible only while its chain remains intact: from
Certification Policy to proof, from proof to producer-owned evidence, from
evidence to an identity-bound Operation Contract, and from the operation to
stable constitutional claims. Providers may change. Runtime values may vary.
The assurance relationship must remain intact.

The lasting architectural idea is simple:

> The unit of assurance is not the component. It is the justified conclusion
> about an identity-bound operation.

TruthFast exists to make that conclusion explicit, falsifiable,
reproducibly verifiable within its defined V1 paths, and no larger than its
evidence.
