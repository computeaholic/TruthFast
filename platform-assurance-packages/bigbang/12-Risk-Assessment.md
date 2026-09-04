# Risk Assessment — Big Bang

Top risks

- Insufficient lifecycle exercises (certificate rotation) — HIGH
- Divergent EC payloads without translators — MEDIUM
- Proof registry immutability assumption mismatch — MEDIUM

Mitigations

- Implement lifecycle harnesses; include rollback plans.
- Require translator deliverables in provider descriptors.
- Use immutable storage for proof registry or use S3 with Object Lock where available.
