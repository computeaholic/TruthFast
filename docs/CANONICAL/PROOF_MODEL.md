# Canonical Proof Model

TruthFast proof is deterministic, fail-closed, and evidence-backed.

## Single proof path
`make proof` -> `scripts/prove_system.sh` -> `scripts/verify/*`

## Proof requirements
- Final status is `PASS`.
- `fail_class` is `NONE`.
- Signed artifacts are present and verifiable.
- Invariants are re-evaluated from artifact content, not signature alone.
- Determinism check confirms consistent proof outcomes.

## Core proof artifacts
- `artifacts/proof/latest/status.json`
- `artifacts/proof/latest/verify.log`
- `artifacts/proof/latest/observe.log`
- `artifacts/proof/latest/ca_integrity.json`
- `artifacts/proof/latest/gateway_ca_source.json`
- `artifacts/proof/latest/failure_behavior.json`
- `artifacts/proof/latest/determinism.json`

## Verification scripts
- `scripts/sign_proof_artifacts.sh`
- `scripts/verify/verify_proof_artifacts.sh`
