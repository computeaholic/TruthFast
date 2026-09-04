# TruthFast Architecture Manifest

This manifest records the canonical documents in the clean TruthFast release tree. Historical engineering records remain in the private ThreadForge repository.

New canonical documents (docs/architecture)

- 00-ThreadForge-Assurance-Reference-Architecture.md — Overview
- 01-Constitution.md — Constitution and invariants
- 02-Constitutional-Principles.md — Principles
- 03-Assurance-Capabilities.md — Capabilities catalog
- 04-Constitutional-Claims.md — Claims registry format
- 05-Evidence-Contracts.md — EC semantics and rules
- schemas/evidence-contract.schema.json — Base EC JSON Schema
- 06-Proof-Architecture.md — Proof lifecycle and registry
- 07-Certification-Architecture.md — Certification model
- 08-Provider-Architecture.md — Provider model and descriptors
- 09-Capability-Bindings.md — Bindings spec
- 10-Profiles.md — Profile rules
- 11-Native-Reference-Implementation.md — Native mapping
- 12-BigBang-Profile.md — Big Bang profile metadata
- ../CANONICAL/ENGINEERING_LEXICON.md — Canonical engineering lexicon
- 14-Governance.md — Governance, ADRs, versioning
- 15-Migration-Strategy.md — Migration phases and tasks
- 16-Repository-Information-Model.md — Repository information architecture and directory contracts
- 17-Concept-Index.md — Canonical concept ownership graph
- repository-manifest.yaml — Machine-readable repository manifest and navigation source
- SYSTEM_ATLAS.md — Implemented V1 system, support, authority, and qualification atlas
- ENGINEERING_DOCTRINE.md — Concise current failed-assumption review principles
- system-model/ — Descriptive machine-readable system, edge, authority, state, and claim model
- system-model/research_doctrine_matrix.json — Descriptive A-AI doctrine adjudication; not an obligation registry
- POST_V1_ARCHITECTURAL_ASSETS.md — Non-blocking research and extraction directions

Mapping of older documents to new canonical locations

- `docs/architecture/ARCHITECTURE.md` -> [00-ThreadForge-Assurance-Reference-Architecture.md](00-ThreadForge-Assurance-Reference-Architecture.md)
- `docs/architecture/PROOF_MODEL.md` -> [06-Proof-Architecture.md](06-Proof-Architecture.md)
- `docs/CANONICAL/TRUST_MODEL.md` -> canonical trust boundary reference for the current repository state
- `repository-manifest.yaml` and `17-Concept-Index.md` -> active ownership and
  implementation traceability
- `docs/index.md` -> Repository information architecture landing page
- `README.md` -> Public repository entry point; links to the repository information architecture
- `reports/research/threadforge-failed-assumption-doctrine-20260828/` -> dated research source record; not constitutional authority

If additional legacy docs conflict with these canonical definitions, update them to reference the canonical doc and remove conflicting statements.

Related operating-model patterns

- `10-Operating-Model/Engineering Patterns/Platform Assurance Packages.md` -> Platform Assurance Package engineering pattern (operational guidance; portable execution packages).

Repository information model

- Repository -> Subsystem -> Owner -> Artifact -> Lifecycle -> Consumers -> Validation -> Evidence
- Navigation and directory contracts are projections of `repository-manifest.yaml`.
- The canonical documentation landing pages are `docs/index.md`, `docs/START_HERE.md`,
  `docs/CANONICAL/README.md`, `docs/operations/README.md`, `docs/governance/README.md`,
  `docs/lifecycle/README.md`, `docs/policies/README.md`, and `docs/releases/README.md`.
