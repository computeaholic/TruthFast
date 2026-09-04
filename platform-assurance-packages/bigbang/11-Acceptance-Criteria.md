# Acceptance Criteria — Big Bang

Minimum acceptance

- All required ECs produced and validated for representative collectors.
- Core claims for Identity and Artifact Integrity assert PASS with confidence >= medium.
- Proof artifacts frozen in Proof Registry and signed; `status.json` signature verifies.

Blocking failures

- Any critical claim with confidence `low` for Identity or Artifact Integrity.
- Missing ECs required by capability bindings.
