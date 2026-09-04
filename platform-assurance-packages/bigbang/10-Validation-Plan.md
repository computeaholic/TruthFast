# Validation Plan — Big Bang

Validation objectives

- Ensure ECs conform to base schema.
- Ensure claims asserted match expectations.
- Ensure certification artifacts meet policy thresholds.

Static validation

- Validate profile file against profile schema.
- Validate provider descriptors include required fields.
- Validate EC JSON instances against `evidence-contract.schema.json` snapshot in appendix.

Runtime validation

- Execute collector smoke runs and verify EC outputs.
- Execute evaluators and verify claim assertions and confidence scores.

Acceptance gating

- See `11-Acceptance-Criteria.md` for pass/fail conditions.
