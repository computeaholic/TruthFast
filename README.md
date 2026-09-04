# TruthFast

TruthFast is a constitutional assurance architecture for bounded assurance
over identity-bound consequential execution. Its native reference
implementation is a fail-closed Kubernetes security proof system.

It enforces identity-bound policy and supply-chain integrity, observes bounded
runtime behavior, then produces cryptographically signed proof artifacts with
semantically deterministic canonical projections.

## Operational Boundary

- Canonical runtime authority: `make validate-all`
- Canonical destructive reconstruction: `make golden-boot`
- Supported reviewer aggregate: `make demo-all`
- Canonical operator diagnostic audit: `make audit`
- CI authority: repository/static/governance only
- Deployment model: Helm owns declarative resources, `threadforge-bootstrap`
  owns runtime-generated resources, and controllers own runtime status
- Manual `kubectl` repair is not part of normal operation

For the conceptual thesis, start with [docs/Agent-Containment.md](docs/Agent-Containment.md).

Current qualification provenance is recorded in
[docs/releases/PUBLIC_RELEASE_PROVENANCE.md](docs/releases/PUBLIC_RELEASE_PROVENANCE.md).
The external project and private engineering lineage are explicitly separated
in [PUBLIC_IDENTITY_RECONCILIATION.md](docs/releases/PUBLIC_IDENTITY_RECONCILIATION.md).
The qualified executable source revision for this release is
`0ddae102badf2a93fe4fdb3934ad9a36db4c8c84`. Detailed operation records in
[CERTIFICATION_BASELINE.md](docs/releases/CERTIFICATION_BASELINE.md) are
historical evidence from an earlier qualified revision and are not relabeled.

---

## What this system proves

| Claim                                  | Mechanism                                                         |
| -------------------------------------- | ----------------------------------------------------------------- |
| Identity-bound workloads               | SPIRE/SPIFFE SVIDs, Kyverno admission enforcement                 |
| SPIRE-authorized trust chain           | Successor/current lineage is accepted across SPIRE, Istio, Envoy; universal retired-root rejection is not claimed |
| Bounded fail-closed SPIRE outage behavior | Normal authority is VAP-blocked; an explicit audited break-glass witness proves post-expiry denial, fresh-request failure, and recovery |
| Signed, internal-only images           | cosign key signing + Kyverno verify policy                        |
| Unauthorized east-west paths blocked   | Istio AuthorizationPolicy + `verify_east_west_blocking.sh`        |
| Test-workload external egress blocked  | Egress lockdown NetworkPolicy + `verify_north_south_boundary.sh`  |
| Semantically deterministic proof projection | `make proof-determinism` — two-run canonical artifact comparison |
| Audit-verifiable enforcement           | SHA-256 chain with cosign-signed genesis and key-registry evidence |

---

## Quick Start

### Reviewer and development setup

TruthFast's native profile is an Ubuntu-hosted, single-node Kind reference
environment. Before using repository checks or runtime commands:

```bash
python3 -m venv .venv
./.venv/bin/python -m pip install -r requirements/dev.txt

# Required only for native runtime execution; reports every missing host tool.
bash scripts/lib/check_prereqs.sh
```

The runtime prerequisite gate checks Docker, Git, Kind, kubectl, cosign, Helm,
jq, Python, skopeo, istioctl, and the Docker daemon. Repository-only inspection
does not require a cluster: start with `make help` and `make docs-verify`.

### Choose the intended execution path

```bash
# Validate an existing, already-converged native runtime
make validate-all

# Reconstruct the canonical native runtime from supported source state
# (destructive; requires a clean worktree and operator-controlled host access)
make golden-boot

# Canonical proof only
make proof

# Determinism check (run twice, compare artifacts)
make proof-determinism

# Active enforcement test
make prove-active

# Supported reviewer demo aggregate (exactly four demos)
make demo-all

# Operator diagnostic audit, separate from proof/certification
make audit
make registry-audit

# Canonical ForgeSec surface
make forgesec
```

`make validate-all` and `make golden-boot` end with `FINAL: PASS` when all
runtime phases pass. Demo and audit targets have their own explicit summaries;
their success must not be inferred from the validation banner.

`make demo-all` runs the four supported reviewer demos: `make demo`, `make
demo-civ`, `make demo-authority-contrast`, and `make
demo-security-boundary`. The aggregate requires zero tracked-source mutation
and reports its source SHA. ForgeSec is reached through the canonical
`make forgesec` target; there is no standalone ForgeSec scanner contract.

---

## How to Read Results

- `PASS` means controls were enforced at runtime, not assumed from configuration
- `FAIL` means at least one guarantee could not be verified from live evidence
- `policy_blocked` in canonical proof means normal authority could not scale
  SPIRE to zero; the separate opt-in `make prove-spire-outage` witness requires
  audited break-glass authority and proves bounded outage and recovery behavior
- `DENIED_POLICY` in hostile review means an explicit Kyverno/VAP rule fired — this is proof-grade enforcement

These results are bounded reference-system evidence. They do not claim
production HA, general Kubernetes portability, independent audit, third-party
certification, or production readiness.

The native profile uses deterministic local reference credentials for its
registry and data services. They are protected by the profile's host, mesh,
identity, and policy boundaries, but they are not production secret-management
guidance. A production adaptation must provision unique credentials and signing
keys through an external secrets/key-management system with appropriate key
custody and rotation.

## License

TruthFast project-owned material is licensed under
[PolyForm Shield 1.0.0](LICENSE). Redistributed third-party components retain
their own licenses and attributions in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), including the preserved
[Apache-2.0 text](THIRD_PARTY_LICENSES/Apache-2.0.txt). The license does not
grant trademark rights or imply production certification, warranty, or
ownership of third-party components.

---

## Documentation

The documentation hierarchy is explicit:

1. [docs/Agent-Containment.md](docs/Agent-Containment.md) — constitutional assurance thesis and native containment model
2. `docs/architecture/` — architectural decomposition, decisions, and implementation structure
3. `docs/CANONICAL/` — normative contracts and authoritative behavioral models
4. operational, validation, evidence, report, and research trees — subordinate material with bounded ownership

The repository information model and navigation surface live in `docs/index.md`. For authoritative definitions, start with:

- [Constitutional Assurance Whitepaper](docs/Agent-Containment.md)
- [Repository information architecture](docs/index.md)
- [Repository information model](docs/architecture/16-Repository-Information-Model.md)
- [Repository manifest](docs/architecture/repository-manifest.yaml)
- [Release evidence and source binding](docs/releases/CERTIFICATION_BASELINE.md)
- [Engineering doctrine](docs/architecture/ENGINEERING_DOCTRINE.md)
- [Research doctrine matrix](docs/architecture/system-model/research_doctrine_matrix.json)

- [00-ThreadForge-Assurance-Reference-Architecture.md](docs/architecture/00-ThreadForge-Assurance-Reference-Architecture.md)
- [01-Constitution.md](docs/architecture/01-Constitution.md)
- [02-Constitutional-Principles.md](docs/architecture/02-Constitutional-Principles.md)
- [03-Assurance-Capabilities.md](docs/architecture/03-Assurance-Capabilities.md)
- [04-Constitutional-Claims.md](docs/architecture/04-Constitutional-Claims.md)
- [05-Evidence-Contracts.md](docs/architecture/05-Evidence-Contracts.md)
- [06-Proof-Architecture.md](docs/architecture/06-Proof-Architecture.md)
- [07-Certification-Architecture.md](docs/architecture/07-Certification-Architecture.md)
- [08-Provider-Architecture.md](docs/architecture/08-Provider-Architecture.md)
- [09-Capability-Bindings.md](docs/architecture/09-Capability-Bindings.md)
- [10-Profiles.md](docs/architecture/10-Profiles.md)
- [11-Native-Reference-Implementation.md](docs/architecture/11-Native-Reference-Implementation.md)
- [12-BigBang-Profile.md](docs/architecture/12-BigBang-Profile.md)
- [docs/CANONICAL/ENGINEERING_LEXICON.md](docs/CANONICAL/ENGINEERING_LEXICON.md)
- [14-Governance.md](docs/architecture/14-Governance.md)
- [15-Migration-Strategy.md](docs/architecture/15-Migration-Strategy.md)
- [17-Concept-Index.md](docs/architecture/17-Concept-Index.md)

Older or implementation-specific artifacts remain in their folders, but the authoritative order is:

`docs/Agent-Containment.md` -> `docs/architecture/` -> `docs/CANONICAL/` -> operational/validation/evidence/archive surfaces.

For the qualified runtime evidence set, see [docs/releases/CERTIFICATION_BASELINE.md](docs/releases/CERTIFICATION_BASELINE.md).

---

## Trust Boundaries

Cluster-admin is the ultimate Kubernetes authority. TruthFast enforces visibility, auditability, break-glass friction, and fail-closed enforcement _below_ the cluster-admin boundary. See [docs/CANONICAL/TRUST_MODEL.md](docs/CANONICAL/TRUST_MODEL.md) for the full boundary statement.
