# TruthFast Engineering Lexicon

This document is the official TruthFast engineering language.
Use these terms in architecture docs, ADRs, scripts, manifest metadata,
validation output, and user-facing repository navigation.

The lexicon is derived from the canonical architecture, repository
information model, and execution model. It intentionally separates:

- ownership from observation
- evidence from projection
- proof from validation
- snapshot from continuity
- completion from execution

## Core language rules

1. Canonical terms are preferred over historical implementation names.
2. A producer owns a state transition; consumers may only observe it.
3. Evidence and projections are derived, not authored independently.
4. Verification is a witness function. Validation is a broader scheduler or
   contract-checking function. Proof is evidence synthesis under a contract.
5. Compatibility names are permitted only when a public surface must remain
   stable and the wrapper is explicit about that role.
6. Historical modifiers such as `real`, `legacy`, `old`, `new`, `latest`,
   `current`, `final`, `closure`, `v2`, and `compat` should be used only when
   they accurately describe a compatibility boundary or archived material.

## Constitutional terms

| Canonical term | Formal definition | Owner / typical surface | Allowed usage | Forbidden or discouraged synonyms | Examples |
| --- | --- | --- | --- | --- | --- |
| Constitution | The authoritative set of architectural objects, rules, and contracts. | `docs/CANONICAL/*`, `docs/architecture/*` | Normative architecture and invariant statements. | ad hoc rules, informal design notes | `docs/Agent-Containment.md` |
| Capability | A top-level responsibility group that owns one class of claims. | Architecture docs, repository manifest | When grouping related claims or providers. | feature bucket, module basket | Capability catalog entries |
| Claim | An atomic declarative invariant asserted about runtime behavior. | Evidence contracts, proof contracts | When stating a testable invariant. | promise, wish, goal | `claim.identity.bound` |
| Evidence Contract | Schema and semantics for evidence artifacts. | Canonical architecture and proof docs | When defining artifact shape and provenance. | log format, report shape | `ec:status-signature` |
| Collector | Component that produces evidence-contract instances. | Proof collectors, validation exporters | When runtime state is captured into evidence. | recorder, scraper, poller (unless it truly only collects) | Proof collectors in `scripts/prove_system.sh` |
| Evaluator | Component that consumes evidence-contract instances and asserts claims. | Proof verifiers, validation checks | When checking evidence against a claim. | judge, reporter | `scripts/verify/verify_proof_artifacts.sh` |
| Provider | Implementation that produces evidence and advertises capabilities. | Runtime modules, platform profiles | When a component is the source of truth for a contract. | engine, backend, adapter (unless context demands) | SPIRE, Istio, cert-manager providers |
| Provider Descriptor | Machine-readable metadata about a provider. | Profiles, manifests | When binding a provider to a capability. | profile hint, config blob | provider manifests |
| Capability Binding | Mapping of a capability to provider roles within a profile. | Profiles, manifests | When describing how a platform realizes a capability. | wiring, glue | profile bindings |
| Profile | Metadata-only mapping for a target platform. | Platform profiles | When selecting provider bindings for a target platform. | deployment recipe, runtime config | Big Bang profile metadata |
| Native Reference Implementation | Canonical example implementation of the constitution. | `scripts/`, `platform/`, `internal/` | When describing the reference runtime. | sample app, demo | TruthFast itself |
| Repository | The TruthFast source tree as a governed engineering system. | Repository model docs | When discussing source ownership and navigation. | codebase, repo dump | `docs/index.md` |
| Subsystem | A bounded directory or subtree with one primary responsibility and one owner. | Repository manifest, landing pages | When assigning ownership to a directory or surface. | area, bucket | `scripts/`, `platform/` |
| Owner | The constitutional steward responsible for an authoritative representation. | Directory contracts, manifest, docs | When assigning responsibility. | maintainer, caretaker | `Automation`, `Platform Runtime` |
| Artifact | A file, manifest, script, report, or generated output with a lifecycle. | All repository surfaces | When classifying repository content. | file, blob, payload | proof artifact, manifest, script |
| Lifecycle | The state of an artifact: authored, generated, validated, archived, or retired. | Manifest, documentation, generated evidence | When describing how a thing is maintained. | status, phase, age | generated proof artifacts |
| Consumer | A person, script, or subsystem that reads or depends on an artifact. | Witnesses, tests, docs | When a surface observes or consumes authority. | downstream, reader | `scripts/verify/*` |
| Validation | The command or proof path that demonstrates an invariant. | `make validate-all`, targeted checks | When the repository schedules and checks contracts. | random test, sanity check | `make validate-all` |
| Archive | A historical surface preserved for reference but excluded from active navigation. | `archive/`, historical docs | When retaining evidence or retired material. | active docs, living docs | `archive/README.md` |
| Generated artifact | Output derived from an authoritative source model. | `artifacts/`, generated manifests | When material is deterministically derived. | authored truth, hand-edited projection | `artifacts/proof/latest/status.json` |
| Canonical | The single authoritative representation of a concept. | Canonical docs, canonical scripts | When one source should be preferred for a concept. | primary-ish, main-ish, real | canonical proof contract |
| Traceability chain | The bidirectional path from architecture to implementation to validation to evidence, and back again. | Repository model docs | When explaining how contracts map to evidence. | trace, lineage, provenance only | Architecture -> Evidence |
| Repository Manifest | Machine-readable inventory of subsystems, owners, contracts, and validation entry points. | `docs/architecture/repository-manifest.yaml` | When describing directory authority and navigation. | index, directory list | repository manifest |
| Landing Page | A concise directory entry that explains purpose, ownership, and validation. | `README.md` files and directory indexes | When introducing a major surface. | overview page, splash page | `docs/index.md` |

## Execution and evidence terms

| Canonical term | Formal definition | Owner / typical surface | Allowed usage | Forbidden or discouraged synonyms | Examples |
| --- | --- | --- | --- | --- | --- |
| Producer | The implementation that creates or transitions state. | Runtime producers, control-plane producers | When a component owns a state transition. | source, emitter, generator (unless literally generating) | control-plane convergence gate |
| Consumer | An implementation that reads, depends on, or witnesses producer state. | Witness scripts, tests, docs | When a surface consumes but does not create authority. | dependent owner, replica | proof witnesses |
| Witness | A consumer that reports evidence without owning the state transition. | `scripts/verify/*`, tests | When checking a producer-owned contract. | validator (unless it is the broader scheduler), judge | `verify_identity_bound_policy.sh` |
| Observer | A read-only evidence capture surface. | Telemetry collectors, probes, proof logs | When collecting evidence without mutation. | actor, controller | `observe.log` |
| Projection | A derived representation of authoritative state. | Generated proof artifacts, manifests | When reporting canonical state from evidence. | source of truth, hand-authored status | `status.json` |
| Evidence | Runtime or proof output derived from producers. | Logs, manifests, frozen proof output | When showing what happened. | truth, source, fact (unless precise) | `verify.log`, `observe.log` |
| Proof | Evidence synthesis and assertion under a contract. | `make proof`, `scripts/prove_system.sh` | When assembling canonical evidence and claims. | test run, check run | proof output |
| Verification | A focused witness or assertion of one contract element. | `scripts/verify/*` | When a check validates a specific invariant. | proof, validation (unless it is the repo scheduler) | `verify_signatures.sh` |
| Validation | The broader repository scheduler or contract-checking path. | `make validate-all`, targeted validation runs | When combining multiple witnesses under one execution graph. | proof, verification | `make validate-all` |
| Certification | The bounded conclusion permitted by complete validated proof and the qualification evidence set. | release baselines, certification docs | When interpreting proof under the current release contract. | approval, blessing, independent certification | `docs/releases/CERTIFICATION_BASELINE.md` |
| Snapshot | A point-in-time witness that certain predicates were simultaneously true. | control-plane gate, trust snapshot | When proving the beginning state of an operation. | readiness, live state, continuous health | `wait_for_control_plane.sh` |
| Operation | A bounded action with a start, end, and identity. | bootstrap, proof, rotation, refresh | When an execution window has an owner. | process, task, job (unless a job is the contract) | proof execution |
| Completion | The identity-bound terminal state of an operation. | Job UID, pod UID, completion record | When observing the exact object that finished. | done, finished, complete-but-unbound | proof job completion |
| Guarantee | An invariant that must hold during an operation or at completion. | proof guarantees, runtime enforcement guarantees | When asserting stable behavior over time. | assumption, expectation | fail-closed guarantee |
| Identity | Stable identity evidence that binds observations to a producer. | SPIFFE IDs, Kubernetes UIDs, Job UIDs | When a contract must prove it observed the right object. | name, label, discovery result | Job UID continuity |
| Authority | The producer permitted to declare or transition a state. | trust root, control-plane producer, policy owner | When one component owns a decision. | source of convenience, guessed owner | SPIRE trust authority |
| Trust | The accepted chain of authority for identity or publication. | SPIRE, trust-root lifecycle, bundle publication | When proving a trust boundary. | confidence, assumption | SPIRE trust root |
| Publication | Making producer-owned state visible to consumers. | registry preload, proof publication, bundle publication | When a producer writes its state for consumption. | announce, expose (unless precise) | proof artifact publication |
| Determinism | Same inputs and state yield the same canonical projection. | `make proof-determinism`, proof freeze logic | When proving replay stability. | repeatability, similarity | normalized proof artifacts |
| Runtime | The live cluster and system state under execution. | Kubernetes workloads, controllers, services | When referring to observed live behavior. | prod, environment, platform (unless specific) | runtime evidence |
| Containment | Enforcement that limits unauthorized action or blast radius. | admission, mesh policy, north/south and east/west controls | When discussing isolation and fail-closed behavior. | safety, protection only | policy containment |
| Policy | A declarative rule constraining runtime behavior. | Kyverno, ValidatingAdmissionPolicy, runtime policy docs | When a rule governs what may execute. | guideline, suggestion | admission policy |
| Execution | The act of running a producer-owned contract. | bootstrap, proof, refresh, rotation | When a contract is being exercised. | invocation, evaluation | proof execution |
| Convergence | The stable state where the required predicates and ownership contracts are simultaneously satisfied. | control-plane gate, proof scheduler | When a contract settles and is ready to be consumed. | readiness alone, eventual consistency slogan | canonical convergence gate |

## Repository model terms

| Canonical term | Formal definition | Owner / typical surface | Allowed usage | Forbidden or discouraged synonyms | Examples |
| --- | --- | --- | --- | --- | --- |
| Constitution | Same as above, but used for repository governance and architectural rules. | Architecture docs | When discussing immutable architecture. | policy, style guide | `docs/architecture/01-Constitution.md` |
| Claim | Same as above, but as a repository-level invariant. | Canonical architecture | When listing proof obligations. | assertion, assumption | claim registries |
| Proof Artifact | Frozen, signed proof material stored in the local canonical proof tree. | `artifacts/proof/latest/` | When describing final proof output. | evidence dump, report | signed proof bundle |
| Proof Registry | A proposed portable index/store for frozen proofs; no deployed V1 service exists. | post-V1 architecture proposals | Only when discussing the proposed post-V1 boundary. | current artifact store, current V1 authority | post-V1 proof registry |
| Certification Policy | The declared acceptance rules that map complete validated claims to a bounded conclusion. | Certification docs and exact-SHA graduation contract | When describing release acceptance criteria. | confidence score, approval checklist | V1 qualification acceptance boundary |
| Capability Binding | Mapping of capabilities to providers within a profile. | Profiles, manifests | When describing platform realization. | configuration map | profile bindings |
| Provider Descriptor | Machine-readable provider metadata. | Profiles and manifests | When describing how a provider is selected. | tag, hint | provider descriptor |
| Native Reference Implementation | The canonical implementation example for the constitution. | Runtime / scripts / platform trees | When describing TruthFast itself as the reference runtime. | demo, sample | TruthFast runtime |
| Artifact | Any file with a defined lifecycle and owner. | Repository manifest | When classifying content. | junk, blob, thing | source file, report, output |
| Lifecycle | The authoritative state of an artifact: authored, generated, validated, archived, retired. | Repository manifest and docs | When classifying retention and navigation. | maturity, age | archived report |
| Archive | Historical content retained for reference. | `archive/`, historical evidence trees | When preserving lineage without active authority. | active docs | closure reports |
| Generated artifact | Output derived from source and not edited as truth. | `artifacts/`, generated manifests | When describing projections or frozen outputs. | source, authored doc | `status.json` |
| Canonical | The single preferred representation of a concept. | Canonical docs and surfaces | When selecting one authority. | primary, best-effort | canonical proof contract |
| Repository Manifest | The machine-readable source of directory ownership and navigation. | `docs/architecture/repository-manifest.yaml` | When discussing directory contracts. | table of contents | manifest |
| Landing Page | Directory entry page for humans and automation. | README files | When introducing a directory or surface. | intro page, portal | `docs/index.md` |

## Naming rules

- Use **Producer** when a surface owns the state transition.
- Use **Consumer** when a surface only reads, depends on, or witnesses the producer.
- Use **Witness** for a focused read-only contract check.
- Use **Observe** for passive collection of runtime evidence.
- Use **Projection** for any derived representation of authoritative state.
- Use **Evidence** for runtime or proof outputs, never for authored claims.
- Use **Snapshot** for point-in-time simultaneous predicates.
- Use **Completion** for identity-bound terminal state.
- Use **Guarantee** for an invariant that must hold across an execution window.
- Use **Verify** for a focused witness or compatibility wrapper that asserts a contract.
- Use **Validate** for the broader scheduler or check that confirms a set of contracts.
- Use **Proof** for the evidence-synthesis pipeline.
- Use **Certification** for signed attestation over proven claims.
- Use **Convergence** for a contract that settles system state and is then consumed.

## Avoid these historical patterns in active names

Use the terms below only when they are genuinely part of a compatibility layer,
archive, or historical artifact:

- `real`
- `legacy`
- `wrapper`
- `compat`
- `final`
- `closure`
- `old`
- `new`
- `latest`
- `current`
- `v2`
