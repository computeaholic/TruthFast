# TruthFast Assurance Reference Architecture

## Purpose

TruthFast is a constitutional assurance architecture for proving and governing
bounded runtime security and trust claims. It separates stable institutional
meaning (claims, capabilities, evidence contracts, providers, and profiles)
from the native implementation that produces and verifies evidence for one
qualified Kind reference profile.

## Scope

This document is the canonical, human-readable summary of TruthFast's constitutional architecture. It explains the problem TruthFast solves, the separation between constitution and implementation, and the high-level models for certification, evidence, providers, and profiles.

## What problem does TruthFast solve?

- Establishes a single, provable source of truth for platform assurance and a
  model intended to support Kubernetes distributions and managed platforms.
  The native qualification is bounded to the tested Kind runtime and does not
  certify general portability.
- Defines product-independent claim and evidence boundaries while current V1
  demonstrates one product-specific implementation using SPIRE, Istio, Cosign,
  and Kubernetes.

## What is constitutional vs implementation?

- Constitutional: versioned architectural meaning (Constitution, Principles,
  Capabilities, Claims, Evidence Contracts, Provider model, Profiles, Proof and
  Certification architecture) that implementation cannot silently weaken.
- Implementation: provider code, scripts, runtime artifacts, and the native TruthFast reference implementation which realizes the constitution but does not alter it.

## How certification works (high level)

- Evidence Contracts define required artifact shape and provenance metadata.
- Collectors produce Proof Artifacts that satisfy Evidence Contracts.
- Evaluators consume Proof Artifacts to assert Constitutional Claims.
- The current local proof tree freezes, hashes, signs, verifies, and source-binds
  canonical proof artifacts.
- Current exact-SHA qualification interprets complete validated guarantees and
  the operation-specific evidence set under the bounded release contract.

## How profiles and providers work

- Profiles: metadata-only specifications that declare capability bindings and provider descriptors for a target platform (e.g., Big Bang, OpenShift).
- Providers: pluggable implementations that produce Evidence Contracts and advertise capabilities. They are replaceable without changing the constitution.

## Native implementation relationship

The native TruthFast implementation is the canonical V1 reference
implementation. It maps components to constitutional objects and is qualified
only for the supported native profile. A future profile must define conformant
bindings and produce the required evidence; profile portability is an
architectural objective, not a current certification claim.

## Who should use this document

Platform architects, security reviewers, and implementers evaluating or
adapting the bounded reference architecture.
