# ADR 0005: Profile Validation and CLI Integration

Status: Proposed

## Context

Profiles must be validated prior to use. A consistent CLI command (e.g., `validate-profile`) simplifies adoption and integration with `make validate-all`.

## Decision

Add a profile validation schema and CLI entrypoint `validate-profile --profile <profile-dir>` that runs static checks. Integration with `make validate-all --profile` is optional and feature-gated.

## Consequences

- PAPs must include a profile manifest compatible with the validator.
- `make validate-all` remains authoritative until profile flag is stable.
