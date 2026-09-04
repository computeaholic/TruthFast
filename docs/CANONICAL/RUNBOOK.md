# Canonical Runbook

## Execute proof
1. Run `make proof`.
2. Verify `artifacts/proof/latest/status.json` reports:
   - `final=PASS`
   - `fail_class=NONE`
   - `evidence.signed=true`
3. Run `bash scripts/verify/verify_proof_artifacts.sh artifacts/proof/latest`.

## Required failure response
- Any `[FAIL]` or `CONTRACT_VIOLATION` in verify artifacts is a proof failure.
- Do not bypass checks with alternative script entrypoints.
- Re-run proof only through `make proof`.

## Evidence handoff
Provide `artifacts/proof/latest/` directory contents and `status.json` for review.
