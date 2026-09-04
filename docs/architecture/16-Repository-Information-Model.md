# Repository Information Model

TruthFast treats repository information as a first-class engineering system.
This document defines the canonical model that should shape directory ownership,
navigation, traceability, and validation.

## Canonical model

```
Repository
  -> Subsystem
  -> Owner
  -> Artifact
  -> Lifecycle
  -> Consumers
  -> Validation
  -> Evidence
```

### Terms

- Repository: the TruthFast source tree as a governed engineering system.
- Subsystem: a bounded area with one primary responsibility and one primary owner.
- Owner: the constitutional steward responsible for the subsystem's authoritative representation.
- Artifact: a file, manifest, script, proof, report, or generated output with a defined lifecycle.
- Lifecycle: authored, generated, validated, archived, or retired.
- Consumers: the places that read the artifact or depend on it.
- Validation: the commands that prove the artifact is correct.
- Evidence: the runtime or proof output that demonstrates behavior.

## Authority rules

1. One subsystem has one primary owner.
2. One authoritative representation is preferred for each concept.
3. Navigation should point to the authoritative representation, not a duplicate.
4. Generated outputs should be derived from their source model.
5. Historical artifacts should not participate in active navigation.

## Machine-readable source of truth

The repository manifest is the machine-readable projection of this model:

- [repository-manifest.yaml](repository-manifest.yaml)

It records the major subsystems, directory contracts, allowed artifact types,
consumers, dependencies, lifecycles, and validation entry points.

## Traceability chain

TruthFast repository information should support both directions:

### Architecture -> Evidence

Architecture -> Implementation -> Validation -> Evidence

### Evidence -> Architecture

Evidence -> Verifier -> Runtime -> Architecture

## Contributor workflows

Use the manifest and directory landing pages to locate authoritative homes:

- Add runtime component: `platform/` -> runtime deployment subtree -> validation entry points.
- Add verifier: `scripts/verify/` -> proof contract or runtime contract witness -> targeted proof validation.
- Add proof: `scripts/proof/` and `artifacts/` -> proof artifacts -> `make proof`.
- Add documentation: `docs/architecture/` for canonical architecture, then the relevant landing page.
- Add ADR: `ADR/` and the impacted canonical documents.
- Add runtime policy: `platform/deploy/` and the associated policy docs under `docs/`.
- Add supply-chain artifact: `platform/config/`, `scripts/supply_chain/`, and the related verification path.
- Add certification evidence: generated `artifacts/` locally, with release provenance in `docs/releases/`; private historical forensics are not part of this clean export.

## Directory contracts

Directory contracts are detailed in the manifest and summarized on the repository
index page. The intent is that each major directory has one clear owner, one
clear purpose, and one clear validation path.

## Documentation promise

This model is the authoritative basis for repository navigation. Supporting
documentation should explain the model, not create parallel models.
