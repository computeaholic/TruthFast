# Canonical Policy Enforcement

TruthFast enforces fail-closed policy at admission and runtime.

## Required enforcement outcomes
- Admission policy matrix passes with deny cases enforced.
- Identity-bound policy evidence is present and passing.
- Containment flow checks enforce allow/deny/egress behavior.
- Runtime drift checks fail when identity or policy contracts degrade.

## Enforcing scripts
- `scripts/verify/verify_policy_validation_matrix.sh`
- `scripts/verify/verify_identity_bound_policy.sh`
- `scripts/verify/test_containment_flows.sh`
- `scripts/tests/test_allow.sh`
- `scripts/tests/test_deny.sh`
- `scripts/tests/test_egress.sh`
- `scripts/verify/verify_runtime_drift.sh`
