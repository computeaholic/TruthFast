# Canonical Red-Team Surface

Red-team evaluation is judged by enforced proof outcomes.

## Required red-team assertions
- Unauthorized paths are denied by policy.
- Identity degradation triggers proof failure.
- Certificate outage behavior remains fail-closed.
- Data-plane readiness must converge and stay stable.

## Verification surfaces
- `scripts/verify/verify_no_cert_issuance_during_outage.sh`
- `scripts/verify/verify_cert_rotation_continuity.sh`
- `scripts/verify/wait_for_data_plane_ready.sh`
- `scripts/verify/verify_runtime_drift.sh`
- `scripts/verify/verify_deterministic_chaos_contracts.sh`

## Evidence artifacts
- `artifacts/proof/latest/failure_behavior.json`
- `artifacts/proof/latest/cert_rotation_validation.json`
- `artifacts/proof/latest/status.json`
