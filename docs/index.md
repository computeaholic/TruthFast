# TruthFast Repository Information Architecture

TruthFast is organized around one canonical information model and one primary conceptual thesis.

- [Constitutional Assurance Whitepaper](Agent-Containment.md)

The whitepaper explains the whole-system containment model. The documents below own the precise contracts and the machine-readable repository model.

## TruthFast documentation hierarchy

This public release preserves the historical ThreadForge documentation hierarchy
as its source lineage while using TruthFast for the external project name.

1. `docs/Agent-Containment.md` — authoritative constitutional assurance thesis and native containment model
2. `docs/architecture/` — architectural decomposition, decisions, and implementation structure
3. `docs/CANONICAL/` — precise normative contracts and authoritative behavioral models
4. `docs/architecture/17-Concept-Index.md` — canonical concept ownership map
5. operational, validation, evidence, report, and research trees — subordinate material with bounded ownership

Repository
  -> Subsystem
  -> Owner
  -> Artifact
  -> Lifecycle
  -> Consumers
  -> Validation
  -> Evidence

Use this page as the repository navigation hub. It points to the authoritative
model, the machine-readable repository manifest, and the major directory landing
pages.

## Start Here

1. [Constitutional Assurance Whitepaper](Agent-Containment.md)
2. [Repository information model](architecture/16-Repository-Information-Model.md)
3. [Repository manifest](architecture/repository-manifest.yaml)
4. [Repository lexicon](CANONICAL/ENGINEERING_LEXICON.md)
5. [TruthFast architecture overview](architecture/00-ThreadForge-Assurance-Reference-Architecture.md)
6. [Concept index](architecture/17-Concept-Index.md)
7. [Engineering doctrine](architecture/ENGINEERING_DOCTRINE.md)
8. [Start Here](START_HERE.md)

## Major directory landing pages

| Directory | Owner | Landing page |
| --- | --- | --- |
| `api/` | Runtime API | [api/README.md](https://github.com/computeaholic/TruthFast/blob/main/api/README.md) |
| `internal/` | Core implementation | [internal/README.md](https://github.com/computeaholic/TruthFast/blob/main/internal/README.md) |
| `platform/` | Runtime and deployment substrate | [platform/README.md](https://github.com/computeaholic/TruthFast/blob/main/platform/README.md) |
| `scripts/` | Automation, verification, and supply chain orchestration | [scripts/README.md](https://github.com/computeaholic/TruthFast/blob/main/scripts/README.md) |
| `tests/` | Regression and validation | [tests/README.md](https://github.com/computeaholic/TruthFast/blob/main/tests/README.md) |
| `docs/` | Canonical documentation | `index.md` |
| `ADR/` | Architectural decisions | [ADR/README.md](https://github.com/computeaholic/TruthFast/blob/main/ADR/README.md) |
| `artifacts/` | Generated proof and certification outputs | Created by supported runtime commands; not included in the clean source export |
| `reports/` | Historical reports and audit evidence | [reports/README.md](https://github.com/computeaholic/TruthFast/blob/main/reports/README.md) |
| `reports/research/` | Failed-assumption research record | [reports/research/README.md](https://github.com/computeaholic/TruthFast/blob/main/reports/research/README.md) |
| `docs/releases/` | Qualification and public-release provenance | [Public release provenance](releases/PUBLIC_RELEASE_PROVENANCE.md) |
| `10-Operating-Model/` | Operating model patterns | [10-Operating-Model/README.md](https://github.com/computeaholic/TruthFast/blob/main/10-Operating-Model/README.md) |

## Primary thesis

| Item | Role | Landing page |
| --- | --- | --- |
| `docs/Agent-Containment.md` | Authoritative constitutional assurance thesis | [Agent-Containment.md](Agent-Containment.md) |
| `docs/architecture/ENGINEERING_DOCTRINE.md` | Concise current review principles; not runtime authority | [ENGINEERING_DOCTRINE.md](architecture/ENGINEERING_DOCTRINE.md) |

## Traceability

Every architectural contract should lead to:

Architecture -> Implementation -> Validation -> Evidence

Every proof or evidence artifact should lead back to:

Evidence -> Verifier -> Runtime -> Architecture

## Conventions

- Active documentation belongs under `docs/`.
- Runtime evidence belongs under `artifacts/` or a historical evidence subtree.
- Historical engineering forensics remain in the private ThreadForge engineering repository; this public export retains only the bounded research record and release documentation.
- Generated artifacts stay generated; authored source stays authoritative.
