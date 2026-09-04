# Gap Analysis — Big Bang

Summary of notable gaps between ThreadForge native reference and Big Bang profile:

- Lifecycle exercise gap: `verify_cert_rotation_continuity` relies on timing-based observation; Big Bang lacks automated signer rotation exercise. Remediation: implement controlled rotation scenario harness.
- Proof registry choices: Native uses file-based `artifacts/`; recommend central immutable registry for production Big Bang runs.
- Provider translation: cosign bundles vs HSM-backed signers require translators to EC schema.

Prioritized remediation

1. Add lifecycle exercise harness for root and leaf certificate rotation.
2. Define Proof Registry adapter (S3/MinIO or immutable object store) and integrate with signing workflow.
3. Create translator adapters for signing payloads.
