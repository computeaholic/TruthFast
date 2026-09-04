# ADR 0003: Proof Registry Interface and Immutability Guarantees

Status: Proposed

## Context

Proof Registry is the canonical place where frozen proof artifacts are stored and queried. Different platforms may use different backing stores.

## Decision

Define a minimal Proof Registry API: store(proof_bundle), get_by_nonce(nonce), get_by_digest(digest), list_proofs(filters). Registry must provide immutability semantics for frozen artifacts and record signer references.

## Consequences

- Providers must implement adapters if they cannot meet immutability semantics.
- PAPs must declare chosen registry adapter in provider descriptors.
