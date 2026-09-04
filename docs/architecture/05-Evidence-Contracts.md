# Evidence Contracts

Evidence Contracts (ECs) define the shape, semantics, integrity, retention, and
bounded verification/re-execution rules for an evidence artifact.

Purpose

- Provide a precise, schematized interface between Collectors (producers) and Evaluators (consumers).

Ownership

- Every EC must list an owner and a version. Owners manage backwards-compatible changes.

Lifecycle and Versioning

- ECs are semantically versioned. Major version changes require migration ADRs.

Required metadata

- `id`, `version`, `producer.provider_id`, `timestamp`, `nonce`, `type`, `digest`, `provenance`, `signatures`, `payload`

Integrity, Replay, Retention

- ECs require canonical digesting and the provenance and retention metadata
  declared by the owning contract. A transparency reference is evidence only
  when the current provider actually emits and verifies it.

Relationship

- Providers implement EC producers; Evaluators consume declared ECs or mapped
  owner-specific native schemas. Current V1 freezes accepted artifacts in the
  local canonical proof tree; it does not operate a portable Proof Registry.

Canonical schema

- See `docs/architecture/schemas/evidence-contract.schema.json` for the base JSON Schema for ECs. Implementers must extend `payload` with EC-specific structure but may not change the base fields.
