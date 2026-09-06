# TruthFast Historical Certification Baseline

This document records bounded runtime qualification and the evidence needed for
release planning. The records below are historical evidence bound to the source
SHAs recorded in each section; they are not the current public-release
qualification record. Any executable change after a qualified SHA requires a
new runtime qualification; documentation-only descendants may retain the
qualification.

## Qualification Status

TruthFast V1 completed the qualification represented below on 2026-08-28. The
current public-release source binding is recorded separately in
`PUBLIC_RELEASE_PROVENANCE.md`.

### Source Binding

- Runtime-qualified SHA: `b7e8612b94089dd574d7064d709427add22dbd51`
- Previous runtime-qualified SHA: `34082cfb4e3b0173f09dc7aeabfa7abb5ad201aa`
- Qualification date: `2026-08-28`
- Branch at qualification: `main`
- Runtime owner: native Kind
- Manual runtime repairs: `0`
- Final operator result: `THREADFORGE EXACT-SHA V1 GRADUATION: PASS`

### Golden Boot

- Operation: `make golden-boot`
- Run ID: `20260827T235010Z-337081`
- Source SHA: `b7e8612b94089dd574d7064d709427add22dbd51`
- Artifact root: `artifacts/mode_runs/20260827T235010Z-337081/`
- Start: `2026-08-27T23:50:10Z`
- End: `2026-08-28T01:29:12Z`
- Duration: `1h 39m 02s`
- Exit code: `0`
- Result: `BOOTSTRAP=PASS`, `PROOF=PASS`, `DETERMINISM=PASS`, `ACTIVE=PASS`,
  `FORGESEC=PASS`, `FINAL=PASS`

### Supported Demo Repeatability

| Operation | Run ID | Source SHA | Result | Source mutation | Manual runtime repairs | Evidence root |
| --- | --- | --- | --- | ---: | ---: | --- |
| `make demo-all` | `supported-demo-all-20260828T022737Z` | `b7e8612b94089dd574d7064d709427add22dbd51` | `4/4 PASS` | `0` | `0` | `artifacts/demo-runs/supported-demo-all-20260828T022737Z/` |
| `make demo-all` | `supported-demo-all-20260828T023321Z` | `b7e8612b94089dd574d7064d709427add22dbd51` | `4/4 PASS` | `0` | `0` | `artifacts/demo-runs/supported-demo-all-20260828T023321Z/` |

The runner stores phase logs under each root and emits the aggregate summary to
the operator stream. Its zero exit requires all four phases to pass with both
`SUPPORTED_DEMO_SOURCE_MUTATION=0` and `MANUAL_RUNTIME_REPAIRS=0`; the final
chained graduation PASS therefore binds those counters to both run IDs.

The four supported demos are `make demo`, `make demo-civ`, `make
demo-authority-contrast`, and `make demo-security-boundary`. Fixtures create
bounded circumstances but do not replace the mechanism being demonstrated.

### Active Assurance and Tamper Evidence

- `make prove-spire-outage`: `PASS`
  - run ID: `20260828T023731Z-spire-outage`
  - source SHA: `b7e8612b94089dd574d7064d709427add22dbd51`
  - evidence: `artifacts/assurance/spire-outage/20260828T023731Z-spire-outage/evidence.json`
  - normal authority: `policy_blocked`
  - outage behavior: existing session `fail_closed`; fresh request `fail`
  - recovery: SPIRE restored, identity reconverged, allowed path HTTP `200`
- `make proof-break-tamper`: `PASS`
  - operation has no producer-emitted run ID
  - valid canonical proof prerequisite: `PASS`
  - tampered isolated copy: rejected by signature verification
  - canonical proof tree: unchanged and subsequently accepted by `make verify-main`

### Proof, Audit, and Repository Integrity

- Final retained proof run ID: `20260828T040045Z-1992684`
- Proof result: `PASS`; guarantees: `28/28 PASS`
- Passive guarantees: `PASS`; active guarantees: `PASS`
- Proof mutation mode: `bounded_active_assurance`
- Proof heals canonical state: `false`
- Signed: `true`; verified: `true`; semantic determinism: `PASS`
- Proof source binding: `artifacts/proof/latest/commit.sha` equals the
  runtime-qualified SHA
- Post-reconstruction registry: durable config `PASS`; explicit CA/TLS
  validation `PASS`; anonymous `/v2/` access denied; authenticated registry
  access `PASS`
- Post-reconstruction SPIRE storage: one `spire-server-data` PVC producer,
  bound, duplicate storage producer `false`
- `make registry-audit`: `PASS`; violations: `0`
  - artifact: `artifacts/registry_audit.json`
  - this operator run emits counts and pass status but no producer run ID;
    its source and operation identity are retained by the qualification log set
- `make audit`: `PASS`
  - run ID: `20260828T032601Z`
  - report: `artifacts/audit/20260828T032601Z/audit_report.json`
  - checks: `8`; status: `PASS`
- `make verify-main`: `PASS`
  - proof signatures, invariant projection, and source binding: `PASS`
  - remote check contract: `NON_BLOCKING`
  - diagnostic checks: `governance`, `publication`, `repository-quality`
- Prometheus qualification state: `24/24` intended targets `UP`, `0` down

`make audit` is an operator diagnostic aggregate. Remote CI checks are
repository/governance signals, not runtime release authority. Neither surface
silently becomes proof or Golden Boot authority.

### Atlas Defect Disposition

| Defect | Final disposition |
| --- | --- |
| `DEF-001` | `CLOSED`: optional API and OperatorCore are explicit secondary surfaces outside native V1 qualification |
| `DEF-002` | `CLOSED`: Prometheus uses verified HTTPS, service-account authentication, stable service routing, and exact `/metrics` RBAC; intended targets are `24/24 UP` |
| `DEF-003` | `CLOSED`: proof is a non-healing witness with explicit passive and bounded active assurance aggregates |

Atlas defects closed: `3/3`. Release defects remaining: `0`.

### Current Resource and Runtime Closeout

- Tempo resource contract: request `1Gi`, limit `2Gi`; owner:
  `platform/deploy/infra/tempo/values.yaml`
- Kyverno admission resource contract: request `256Mi`, limit `2Gi`; owner:
  `scripts/infra/apply_resource_tiering.sh`
- New OOM events: Tempo `0`, Prometheus `0`, Loki `0`, Grafana `0`, OTEL `0`,
  Kyverno `0`
- Unexpected restart deltas: `0`

### Release Boundary Adjudication

- The qualification evidence is an evidence set, not one operation: Golden
  Boot, each demo aggregate, outage assurance, proof tamper, registry audit,
  audit, and verify-main retain separate run identities.
- A continuation wrapper initially used host `curl` without the repository CA
  and reported TLS error 60. This was not the canonical registry trust
  contract. The repository-supported explicit CA/TLS check subsequently passed
  with authenticated `/v2/` access and anonymous access denied; the wrapper
  caveat is retained rather than presented as a qualification failure.
- `v1.0.0-reference-runtime` points to historical commit
  `d0660f375467b77a482c01b20285d5954133db35`; it is retained and not moved.
  No current runtime-qualified tag or GitHub release exists.
- The historical engineering baseline used Apache License 2.0 for project-owned
  material. The current TruthFast public export uses PolyForm Perimeter License
  1.0.1;
  redistributed tracked binaries and their Apache-2.0, BSD, and MIT dependency
  attribution remain recorded in `THIRD_PARTY_NOTICES.md`. Licensing is
  repository provenance and does not alter or extend runtime qualification.
- Seven tracked native binaries total 110,997,616 bytes. They are retained
  because build and deployment consumers were not removed in this closeout;
  binary reduction is a bounded post-V1 repository-size program.
- Hermeticity remains bounded by four external dependency classes: PyPI
  development tooling, upstream OCI sources mirrored into the local registry,
  upstream Helm/chart content, and Sigstore Rekor. The native runtime uses the
  local registry after reconstruction, but a fresh clone still requires the
  documented host/network prerequisites.

### Cold Review Disposition

The 19-finding cold review is reconciled against the qualified SHA: the two
producer defects (durable registry configuration and duplicate SPIRE storage
declaration) are closed and requalified; the ten remaining V1 credibility and
navigation findings are closed without runtime semantics changes; two bounded
limitations are documented; two items remain intentional post-V1 work; and
three historical/no-action findings remain preserved as historical evidence.
No known runtime release defect remains. Repository licensing and redistributed
binary provenance are explicit; binary reduction remains a separate post-V1
repository-size program.

### Engineering Provenance Flags

- `DEVFORGE_ADJUDICATION_COMPLETED=true`
- `AUDIT_SYSTEM_RECONCILED=true`
- `ATLAS_DEFECTS_CLOSED=3/3`
- `RELEASE_DEFECTS_REMAINING=0`
- `COLD_REVIEW_FINDINGS=19; CLOSED_AND_REQUALIFIED=2; CLOSED_NON_RUNTIME=10; DOCUMENTED_LIMITATIONS=2; POST_V1=2; NO_ACTION=3`
- Evidence is internal engineering provenance, not an external audit,
  third-party certification, production-readiness claim, or HA certification.

## Historical Evidence Snapshots

The sections below retain earlier source-bound evidence for traceability. They
are historical records only; their older SHAs, dates, demo states, and resource
values must not be read as the current release qualification.

## Historical Certification Candidate

- Repository: `computeaholic/TruthFast`
- Commit SHA: `43330210495605c6088424c69c8ec3f50b75a77c`
- Branch: `main`
- Date: `2026-08-13`

## Historical Native Platform Assurance Package

- Supported platform: Ubuntu host with the declared persistent native host contract
- Supported bootstrap: canonical destructive reconstruction via `make golden-boot`
- Validation entrypoint: `make validate-all`
- CI authority: repository/static/governance only
- Release boundary: canonical repository content on `origin/main`

## Historical Golden Boot Evidence Closeout

- Canonical wrapper target: `make golden-boot`
- Recorded wrapper command metadata: `make validate-all-full-reset`
- Run ID: `20260813T183441Z-2638472`
- Source SHA: `43330210495605c6088424c69c8ec3f50b75a77c`
- Start TS: `2026-08-13T18:34:41Z`
- End TS: `2026-08-13T20:07:02Z`
- Duration: `1h 32m 21s`
- Exit code: `0`
- Native runtime: `kind`
- NAMESPACE_CONTRACT_PREFLIGHT: `python3 scripts/verify/namespace_contract.py`
- HOST_TRUST_PREFLIGHT: `make native-host-contract-verify`

## Historical Golden Boot Result

- BOOTSTRAP: PASS
- PROOF: PASS
- DETERMINISM: PASS
- ACTIVE: PASS
- FORGESEC: PASS
- FINAL: PASS

## Historical Bounded Claim

On the tested Ubuntu host satisfying TruthFast's declared persistent native
host contract, the tested repository revision successfully executed the
canonical `make golden-boot` lifecycle, reconstructed the canonical native Kind
runtime, and completed the authoritative validation graph through `FINAL: PASS`
without manual runtime repair.

This closeout records the observed bootstrap/validation contract. It does not
claim that the separate functional observability audit has completed every
dashboard, query, trace, or cross-signal check.

## Historical Required Prerequisites

- Platform tools installed per repository documentation
- Registry authentication available for the canonical internal registry
- Required directories and secrets created by the documented bootstrap flow
- Network access to the internal registry and cluster bootstrap dependencies
- Active host privilege for the documented Docker trust mutation path when
  `make golden-boot` reconstructs the native runtime

## Historical Repository Truth Sources

- Canonical architecture: `docs/architecture/`
- Canonical release documentation: `docs/CANONICAL/`
- Bootstrap and verification flow: `README.md` and `docs/START_HERE.md`
- Documentation boundary mapping: `docs/architecture/_manifest.md`

## Historical Certification Scope

This baseline certifies the repository state that was merged to `origin/main`
and verified through the release-facing checks associated with registry
preflight, required image validation, and bootstrap documentation alignment.

The baseline does not add new architecture. It records the certified artifact so
future clean-room reproduction can compare against the same release boundary.

## Historical Evidence Paths

- GOLDEN_BOOT_LOG: `artifacts/mode_runs/20260813T183441Z-2638472/golden-boot.log`
- GOLDEN_BOOT_SUMMARY: `docs/releases/CERTIFICATION_BASELINE.md`
- OTHER_CANONICAL_EVIDENCE:
  - `artifacts/mode_runs/20260813T183441Z-2638472/metadata.env`
  - `artifacts/host_trust/host_trust_status.json`
  - `artifacts/proof/latest/status_staging.json`
  - `artifacts/proof/latest/verify.log`
  - `artifacts/proof/latest/observability.json`

## Historical Runtime Evidence Addendum

The following addendum records the runtime lineage observed at that time. It is
intentionally retained as historical evidence and is not the current
qualification above.

### Historical Golden Boot Evidence

- Historical Golden Boot run ID: `20260813T183441Z-2638472`
- Specimen SHA: `43330210495605c6088424c69c8ec3f50b75a77c`
- Exit: `0`
- Result: `BOOTSTRAP=PASS`, `PROOF=PASS`, `DETERMINISM=PASS`, `ACTIVE=PASS`,
  `FORGESEC=PASS`, `FINAL=PASS`
- Manual runtime repairs: `0`
- Evidence root: `artifacts/mode_runs/20260813T183441Z-2638472/`

### Historical Functional Observability

- `GRAFANA_FUNCTIONAL=PASS`
- `LOKI_FUNCTIONAL=PASS`
- `TEMPO_FUNCTIONAL=PASS`
- `OTEL_PIPELINE_FUNCTIONAL=PASS`
- `CROSS_SIGNAL_CORRELATION=PASS`
- `NEGATIVE_CASE_OBSERVABILITY=PASS`
- `TEMPO_NEW_OOM_EVENTS=0`

Proven correlation operation:

- `OPERATION_ID=f12ea6d1e37bdf051f4c49ca519078b0`
- `TRACE_ID=f12ea6d1e37bdf051f4c49ca519078b0`
- `WORKLOAD_IDENTITY=threadforge-observe`

Proven bounded negative case:

- Actor: `spiffe://identity.threadforge.local/ns/threadforge-test/sa/test-client`
- Action: in-mesh Prometheus readiness request
- Expected: HTTP 403
- Actual: HTTP 403

Historical observability proof artifact roots:

- `artifacts/proof/latest/status.env`
- `artifacts/proof/latest/status.json`
- `artifacts/proof/latest/observe.log`
- `artifacts/proof/latest/observability.json`
- `artifacts/proof/latest/verify.norm.log`

### Historical Canonical Proof Surfaces

- `make proof=PASS`
  - evidence root: `artifacts/proof/latest/`
  - run ID: `20260814T032237Z-2334870`
- `make proof-determinism=PASS`
  - determinism evidence:
    - `DRIFT_CLASS=operational_artifact_drift`
    - `FIRST_DRIFT_ARTIFACT=bootstrap.log`
    - `FIELD=$byte_diff`
    - `SEMANTIC_DETERMINISM=PASS`
- `make prove-active=PASS`
  - demonstrated behaviors:
    - certificate rotation serial changed
    - invalid pod rejected
    - ephemeral containers blocked
    - valid pod accepted

### Historical Supported Optional Demonstrations

These were reviewer-facing demonstrations at the time. They are retained as
historical evidence and are not the current aggregate qualification.

| Demo | Status | Evidence roots |
| --- | --- | --- |
| `make demo-civ` | PASS | `artifacts/civ/cpu-governance-test/20260814T173546Z/`, `artifacts/civ/memory-governance-test/20260814T173546Z/`, `artifacts/civ/identity-attribution-test/20260814T173546Z/` |
| `make demo-authority-contrast` | PASS | `artifacts/civ/identity-enrichment-test/baseline/20260814T173553Z/`, `artifacts/civ/identity-enrichment-test/minimal-authority/20260814T173555Z/`, `artifacts/civ/identity-enrichment-test/full-authority/20260814T173558Z/` |
| `make demo-security-boundary` | PASS | `artifacts/forgesec/20260814T173602Z/` |

`make demo-civ` exercised the civ CPU, memory, and identity-attribution
surfaces. Its CPU governance stress test is the active CIV "IRONMAN DEMO"
path. `make demo-authority-contrast` exercises the civ identity-enrichment
contrast across baseline, minimal-authority, and full-authority phases.
`make demo-security-boundary` exercises the ForgeSec boundary scan.

### Historical Additional Supported CIV Surfaces

These reviewer-facing surfaces were recorded as passing on that historical
mainline:

| Surface | Status | Evidence roots |
| --- | --- | --- |
| `make civ-status` | PASS | live read-only output |
| `make civ-identity-attribution-test` | PASS | `artifacts/civ/identity-attribution-test/20260814T180537Z/` |
| `make civ-sbom-governance-test` | PASS | `artifacts/civ/sbom-governance-test/20260814T180112Z/` |
| `make civ-network-governance-test` | PASS | `artifacts/civ/network-governance-test/20260814T180112Z/` |
| `make civ-io-governance-test` | PASS | `artifacts/civ/io-governance-test/20260814T180113Z/` |
| `make civ-identity-enrichment-test` | PASS | `artifacts/civ/identity-enrichment-test/20260814T180526Z/` |
| `make civ-governance-stress-test` | PASS | `artifacts/civ/governance-stress-test/20260814T180528Z/` |
| `make civ-authority-noncreation-test` | PASS | `artifacts/civ/authority-noncreation-test/20260814T180511Z/` |

### Historical Kyverno Admission OOM Closeout

- Historical Kyverno admission-controller pod:
  - `kyverno-admission-controller-578c67db7-j95px`
  - last termination reason: `OOMKilled`
  - last exit code: `137`
  - last OOM timestamp: `2026-08-13T18:56:12Z`
- Historical deployment contract:
  - requests: `256Mi`
  - limits: `1Gi`
  - resource owner: `scripts/infra/apply_resource_tiering.sh`
  - canonical reconciliation entrypoint: `scripts/infra/apply_resource_tiering.sh`
    (invoked by `scripts/infra/bootstrap.sh`)
- Historical live state after the evidence package:
  - repaired pod: `kyverno-admission-controller-5fb44fdcb-5s48f`
  - restart count: `0`
  - no new Kyverno OOM events were introduced by the evidence runs
  - valid admission was exercised via
    `platform/deploy/infra/spire-csr/spire-csr.yaml`
  - invalid admission was rejected via `tests/invalid/no-resources.yaml`
  - ephemeral-container admission was rejected via `kubectl debug` against the
    `threadforge-test/test-client` workload at that time
  - live container usage was not directly readable from the minimal Kyverno
    image or the unavailable metrics API in this environment

This records the historical OOM as retained evidence, not as an active
regression. That historical run set did not add a new OOM event.

### Historical Runtime Evidence Package — 2026-08-15

This package records a later historical runtime lineage without rewriting the
earlier evidence above.

#### Historical Golden Boot and Functional Observability

- `GOLDEN_BOOT=PASS`
- `FUNCTIONAL_OBSERVABILITY=PASS`
- `CROSS_SIGNAL_CORRELATION=PASS`
- `NEGATIVE_CASE_OBSERVABILITY=PASS`
- `TEMPO_NEW_OOM_EVENTS=0`

Historical canonical observability evidence:

- correlation operation:
  - `OPERATION_ID=f12ea6d1e37bdf051f4c49ca519078b0`
  - `TRACE_ID=f12ea6d1e37bdf051f4c49ca519078b0`
  - `WORKLOAD_IDENTITY=threadforge-observe`
- bounded negative case:
  - actor: `spiffe://identity.threadforge.local/ns/threadforge-test/sa/test-client`
  - action: in-mesh Prometheus readiness request
  - expected: `HTTP 403`
  - actual: `HTTP 403`

#### Historical Canonical Proof Surfaces

- `make proof=PASS`
  - evidence root: `artifacts/proof/latest/`
  - run ID: `20260814T032237Z-2334870`
- `make proof-determinism=PASS`
  - determinism evidence:
    - `DRIFT_CLASS=operational_artifact_drift`
    - `FIRST_DRIFT_ARTIFACT=bootstrap.log`
    - `FIELD=$byte_diff`
    - `SEMANTIC_DETERMINISM=PASS`
- `make prove-active=PASS`
  - demonstrated behaviors:
    - certificate rotation serial changed
    - invalid pod rejected
    - ephemeral containers blocked
    - valid pod accepted

#### Historical Supported Optional Demonstrations

These were reviewer-facing demonstrations only. They were not canonical proof
authority and are not the current aggregate evidence.

| Demo | Classification | Status | Evidence roots | Notes |
| --- | --- | --- | --- | --- |
| `make demo` | SUPPORTED_OPTIONAL_DEMO | BLOCKED | `artifacts/demo-runs/optional-demo-make-demo-20260815T001513Z/` | The containment demo could not complete because the agents-lab prerequisite was absent at that time. |
| `make demo-civ` | WRAPPER | PASS | `artifacts/demo-runs/optional-demo-make-demo-civ-20260815T002954Z/`, `artifacts/civ/cpu-governance-test/20260815T002954Z/`, `artifacts/civ/memory-governance-test/20260815T002955Z/`, `artifacts/civ/identity-attribution-test/20260815T002954Z/` | CPU governance, memory governance, and identity attribution all completed successfully; SBOM remains opt-in/manual. |
| `make demo-authority-contrast` | SUPPORTED_OPTIONAL_DEMO | PASS | `artifacts/demo-runs/optional-demo-authority-contrast-20260815T003003Z/`, `artifacts/civ/identity-enrichment-test/baseline/20260815T003004Z/`, `artifacts/civ/identity-enrichment-test/minimal-authority/20260815T003006Z/`, `artifacts/civ/identity-enrichment-test/full-authority/20260815T003009Z/` | Baseline, minimal-authority, and full-authority phases all executed. The identity-enrichment test remained bounded and reported 0 attributed rows because no evidence rows were present. |
| `make demo-security-boundary` | WRAPPER | PASS | `artifacts/demo-runs/optional-demo-security-boundary-20260815T003156Z/`, `artifacts/forgesec/20260815T003156Z/` | ForgeSec boundary scan completed successfully in that historical runtime. |

#### Historical Kyverno Admission OOM Closeout

- historical OOM pod: `kyverno-admission-controller-578c67db7-j95px`
- historical OOM state: `OOMKilled`
- historical live pod: `kyverno-admission-controller-578c67db7-6zpkx`
- historical restart count: `0`
- historical state: `running`
- historical last termination: `{}`
- historical resource contract:
  - requests: `256Mi`
  - limits: `512Mi`
  - resource owner: `platform/deploy/infra/kyverno/values.yaml`
- historical live usage:
  - `MEM=51.72MB`
  - `VmRSS=116872 kB`
  - `VmHWM=142816 kB`
- root cause class: `G` historical cause no longer reconstructable
- no new Kyverno OOM events were introduced by the evidence runs

The historical OOM is retained as evidence, not erased. That historical live
Kyverno pod was healthy and below its resource limit at capture time.
