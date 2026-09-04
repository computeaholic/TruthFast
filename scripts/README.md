# SCRIPT AUTHORITY MODEL

This directory is the operational surface for ThreadForge automation. The
repository information model, directory contracts, and navigation live in
`docs/index.md` and `docs/architecture/repository-manifest.yaml`.

## Authoritative (fail-closed, proof-critical)

* scripts/prove_system.sh
* scripts/verify/*
* scripts/supply_chain/*
* scripts/sign_proof_artifacts.sh
* scripts/verify/verify_proof_artifacts.sh

Rules:

* MUST exit non-zero on failure
* POLICY_VIOLATION = exit 2
* Used by make proof and CI
* Define system correctness

## Advisory (non-authoritative)

* scripts/advisory/*
* scripts/doctor-*
* scripts/security/* (unless explicitly delegated)

Rules:

* MAY exit 0 on failure
* MUST NOT influence FINAL status
* Used for diagnostics and pre-checks

## Wrappers

* Any duplicate script name MUST be a wrapper
* Wrapper MUST forward to authoritative implementation
* Wrapper MUST NOT contain independent logic

## Execution Rule

ONLY the canonical proof path defines system validity:

make proof

Any script executed outside this path is non-authoritative.
