# Capability Bindings — Big Bang

This document contains the capability bindings for `profile:bigbang:v1`. Bindings map capabilities to provider roles and required Evidence Contracts.

- Capability: Identity
  - providers: ["provider:bigbang/spire"]
  - required_ecs: ["ec:identity-svid-capture","ec:ca-bundle"]

- Capability: Artifact Integrity
  - providers: ["provider:bigbang/cosign","provider:bigbang/harbor"]
  - required_ecs: ["ec:hash-manifest","ec:artifact-signature","ec:status-signature"]

- Capability: Observability and Forensics
  - providers: ["provider:bigbang/monitoring"]
  - required_ecs: ["ec:trace-capture","ec:logs-index","ec:collector-completeness"]

Notes

- Bindings are versioned with the profile. Changes to capability semantics require ADR approval.
