# ADR 0001: ThreadForge Constitutional Architecture

Status: Accepted

## Context

ThreadForge began as a native reference implementation mixing architectural intent with product-specific code. To enable portability and profile-driven deployments (Big Bang, OpenShift, etc.), we need a constitutional layer.

## Decision

Adopt a constitutional architecture separating immutable architectural objects (Constitution) from implementations (Providers, Profiles, Native Reference Implementation). Create `docs/architecture/` as the authoritative location and require ADRs for constitutional changes.

## Consequences

- All future architectural objects live under `docs/architecture/`.
- Profiles are metadata-only; providers implement ECs and advertise capabilities.
- Migration work will follow the phases in `15-Migration-Strategy.md`.
