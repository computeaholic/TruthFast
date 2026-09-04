# Architecture Overview — Big Bang PAP

This document summarizes how the constitutional architecture maps to Big Bang. It is intentionally concise; refer to the appended constitutional snapshots for authoritative definitions.

Mapping principles

- Profiles are metadata-only and contain bindings to providers.
- Providers implement Evidence Contracts; Translators adapt provider-specific payloads to EC schema where necessary.

High-level mapping

- Capability: Identity → Provider: `provider:bigbang/spire`
- Capability: Artifact Integrity → Provider: `provider:bigbang/cosign`
- Capability: Observability → Provider: `provider:bigbang/monitoring` (Grafana/Tempo/Loki)

Key constraints

- PAP assumes isolated VM execution for implementation tasks.
- PAP avoids referencing the ThreadForge development environment.
