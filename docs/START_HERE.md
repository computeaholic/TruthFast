# TruthFast: Start Here

This document is the first read for anyone reviewing TruthFast. It explains what the system is, what it proves, how to run it, and where to go next.

---

## First Read

If you want the conceptual model first, read the [TruthFast Constitutional Assurance Whitepaper](Agent-Containment.md) before the implementation and proof details below.

The documentation order is:

1. `docs/Agent-Containment.md`
2. `docs/index.md`
3. `docs/architecture/`
4. `docs/CANONICAL/`
5. `docs/architecture/17-Concept-Index.md`
6. operational, validation, evidence, report, and research surfaces

## What is TruthFast?

TruthFast is a constitutional assurance architecture for bounded assurance
over identity-bound consequential execution. Its native reference
implementation is a fail-closed Kubernetes security proof system that:

1. Enforces identity-bound policy and supply-chain constraints at admission time
2. Verifies enforcement from live runtime evidence (not configuration alone)
3. Produces a cryptographically signed, deterministic proof of that enforcement

Current release provenance is recorded in [docs/releases/PUBLIC_RELEASE_PROVENANCE.md](releases/PUBLIC_RELEASE_PROVENANCE.md). The qualified executable source SHA is `0ddae102badf2a93fe4fdb3934ad9a36db4c8c84`; detailed records in `CERTIFICATION_BASELINE.md` are historical and remain bound to their recorded source SHA.

The implemented whole-system map is the [TruthFast System Atlas](architecture/SYSTEM_ATLAS.md).

## Operational Boundary

- Canonical runtime authority: `make validate-all`
- Canonical destructive reconstruction: `make golden-boot`
- Supported reviewer aggregate: `make demo-all`
- Canonical operator diagnostic audit: `make audit`
- GitHub Actions authority: repository/static/governance only
- Deployment model: Helm owns declarative resources, `threadforge-bootstrap`
  owns runtime-generated resources, and controllers own runtime status
- Manual `kubectl` repair is not part of the normal flow

---

## Architecture in 60 Seconds

```
Cluster: Kyverno + Istio + SPIRE + VAPs
  ↓ enforcement at admission + runtime
prove_system.sh (fail-closed orchestrator)
  ↓ runs scripts/verify/* against live runtime
artifacts/proof/latest/ (signed evidence)
  ↓ verified by verify_proof_artifacts.sh
make validate-all (full system validation)
```

**Trust root**: SPIRE (single). Successor trust-root publication is SPIRE-owned and TruthFast only witnesses it. Active authority, issuance authority, and
bundle membership remain distinct during legitimate rollover; the selected
runtime lineage must be coherent across SPIRE, Istio, and Envoy. Qualification
establishes successor acceptance and current-lineage convergence at those
consumers, not universal behavioral rejection of every retired predecessor.
All workload identities are SPIFFE SVIDs issued through the SPIRE to istiod CSR
path. There is no self-signed Istio CA in use.

**Fail-closed**: every admission-webhook enforcement path uses
`failurePolicy: Fail`. Webhook timeout -> pod rejected. Observability stack
absent -> proof fails. Normal-authority SPIRE scale-to-zero -> denied by VAP.
The separate opt-in outage witness requires explicit audited break-glass
authority before inducing and recovering from a real outage.

---

## Prepare a Fresh Clone

The native V1 profile is an Ubuntu-hosted, single-node Kind reference
environment. Install repository tooling first:

```bash
python3 -m venv .venv
./.venv/bin/python -m pip install -r requirements/dev.txt
```

Repository-only review can now use `make help` and `make docs-verify` without a
cluster. Before native runtime execution, run the fail-fast host contract:

```bash
bash scripts/lib/check_prereqs.sh
```

It checks Docker, Git, Kind, kubectl, cosign, Helm, jq, Python, skopeo,
istioctl, and the Docker daemon. `make validate-all` validates an existing
converged runtime; `make golden-boot` is the destructive clean reconstruction
path and requires a clean worktree plus operator-controlled host access.

## How to Run the Proof

```bash
# Validate an existing, already-converged native runtime
make validate-all

# Destructive reconstruction from supported source state
make golden-boot

# Canonical non-healing proof with bounded active assurance
make proof

# Determinism check
make proof-determinism

# Active enforcement test (cert rotation, admission)
make prove-active

# Supported reviewer aggregate: containment, CIV, authority contrast, security boundary
make demo-all

# Separate operator diagnostics
make audit
make registry-audit
make containment-audit
make value-plane-audit
make audit-check
make ci-audit

# Canonical ForgeSec surface
make forgesec
```

`make validate-all` and `make golden-boot` end with `FINAL: PASS` when all
runtime phases pass. Demos and audits report their own operation-specific
summaries.

---

## How to Read Results

### `make validate-all` output

```
THREADFORGE VALIDATION SUMMARY
BOOTSTRAP: PASS
PROOF:      PASS
DETERMINISM: PASS
ACTIVE:     PASS
FORGESEC:   PASS
FINAL:      PASS
```

### `artifacts/proof/latest/status_staging.json`

- `final: "PASS"` — all defined guarantees passed
- `fail_class: "NONE"` — no CONTRACT_VIOLATION
- `identity_root: "spire"` — trust root confirmed
- `passive_guarantees: "PASS"` — passive guarantee aggregate passed
- `active_guarantees: "PASS"` — bounded active guarantee aggregate passed
- `proof_heals_canonical_state: false` — proof did not reconcile producer state
- `failure_behavior.json`: `spire_outage: "policy_blocked"` — normal authority was blocked by VAP (correct)

### Common questions

**Q: Why does canonical proof still report `policy_blocked` for SPIRE outage?**
A: Canonical proof has normal authority, so `protect-spire-availability` must
deny its scale-to-zero request. Real outage behavior is a separate operation:
`make prove-spire-outage` first proves the normal denial, then requires explicit
audited break-glass authority. The qualified outage run proved an existing
session failed closed after SVID expiry, a fresh identity-dependent request
failed during the outage, and the restored identity path reconverged before an
allowed request returned HTTP 200.

**Q: What is the supported demo path?**
A: Run `make demo-all`. It executes exactly `make demo`, `make demo-civ`,
`make demo-authority-contrast`, and `make demo-security-boundary`, and fails if
tracked source changes during the run. These are reviewer demonstrations, not
independent proof authority.

**Q: What does `make audit` prove?**
A: It is the canonical operator diagnostic aggregate. Its report is separate
from `make proof` and does not silently become part of Golden Boot or proof.

---

## Where to Go Next

| If you want to understand...           | Read...                                                                                |
| -------------------------------------- | -------------------------------------------------------------------------------------- |
| Constitutional assurance thesis        | [Constitutional Assurance Whitepaper](Agent-Containment.md)                            |
| Repository information architecture    | [Repository information architecture](index.md)                                       |
| Implemented V1 system atlas             | [TruthFast System Atlas](architecture/SYSTEM_ATLAS.md)                               |
| Machine-readable system model           | [System model](architecture/system-model/README.md)                                    |
| Directory ownership and navigation     | [Repository information model](architecture/16-Repository-Information-Model.md)       |
| Repository lexicon                     | [TruthFast engineering lexicon](CANONICAL/ENGINEERING_LEXICON.md)                  |
| Concept ownership map                  | [Architecture concept index](architecture/17-Concept-Index.md)                        |
| Repository manifest                    | [Repository manifest](architecture/repository-manifest.yaml)                           |
| Certified release baseline             | [releases/CERTIFICATION_BASELINE.md](releases/CERTIFICATION_BASELINE.md)              |
| Trust root and cluster-admin boundary  | [CANONICAL/TRUST_MODEL.md](CANONICAL/TRUST_MODEL.md)                                   |
| Identity model in depth                | [CANONICAL/IDENTITY.md](CANONICAL/IDENTITY.md)                                         |
| Attack surface and enforcement layers  | [CANONICAL/SECURITY_MODEL.md](CANONICAL/SECURITY_MODEL.md)                             |
| Audit chain and break-glass            | [CANONICAL/AUDIT_MODEL.md](CANONICAL/AUDIT_MODEL.md)                                   |
| Observability requirements             | [CANONICAL/OBSERVABILITY.md](CANONICAL/OBSERVABILITY.md)                               |
| What PASS/FAIL/CONTRACT_VIOLATION mean | [CANONICAL/PROOF_CONTRACT.md](CANONICAL/PROOF_CONTRACT.md)                             |
| Proof system mechanics                 | [CANONICAL/PROOF_MODEL.md](CANONICAL/PROOF_MODEL.md)                                   |
| Red-team model                         | [CANONICAL/REDTEAM.md](CANONICAL/REDTEAM.md)                                           |

### Directory landings

| If you want to understand... | Read... |
| --- | --- |
| Runtime API surface | [api/README.md](https://github.com/computeaholic/TruthFast/blob/main/api/README.md) |
| Core implementation packages | [internal/README.md](https://github.com/computeaholic/TruthFast/blob/main/internal/README.md) |
| Deployment and build substrate | [platform/README.md](https://github.com/computeaholic/TruthFast/blob/main/platform/README.md) |
| Orchestration and verification scripts | [scripts/README.md](https://github.com/computeaholic/TruthFast/blob/main/scripts/README.md) |
| Regression tests | [tests/README.md](https://github.com/computeaholic/TruthFast/blob/main/tests/README.md) |
| Canonical architecture surface | [CANONICAL/README.md](CANONICAL/README.md) |
| Operations surface | [operations/README.md](operations/README.md) |
| Governance surface | [governance/README.md](governance/README.md) |
| Lifecycle surface | [lifecycle/README.md](lifecycle/README.md) |
| Policy registry | [policies/README.md](policies/README.md) |
| Release evidence | [releases/README.md](releases/README.md) |
| Public release provenance | [releases/PUBLIC_RELEASE_PROVENANCE.md](releases/PUBLIC_RELEASE_PROVENANCE.md) |
| Generated evidence | Created by supported runtime commands under `artifacts/`; not committed in this clean source export |
| Architectural decisions | [ADR/README.md](https://github.com/computeaholic/TruthFast/blob/main/ADR/README.md) |
| Research record | [reports/research/README.md](https://github.com/computeaholic/TruthFast/blob/main/reports/research/README.md) |
| Reports | [reports/README.md](https://github.com/computeaholic/TruthFast/blob/main/reports/README.md) |

---

## No Tribal Knowledge Required

Every claim made by the proof system maps to:

- A specific enforcement script under `scripts/verify/`
- A specific artifact in `artifacts/proof/latest/`
- A specific guarantee in `status_staging.json`

If a result is unclear, read the corresponding script. The proof system does not produce `PASS` from assumed state — it derives it from live runtime evidence at execution time.
