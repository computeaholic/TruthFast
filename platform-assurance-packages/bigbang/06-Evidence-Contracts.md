# Evidence Contracts — Big Bang

This document reproduces the canonical Evidence Contract base schema and lists ECs required by the Big Bang profile. It contains embedded snapshots of the base schema to make the PAP self-contained.

Base EC schema (excerpt)

See `appendix/evidence-contract.schema.json` for the full snapshot included in this PAP.

Required ECs for Big Bang

- `ec:identity-svid-capture` — captures SVIDs, chain, and issuer metadata.
- `ec:ca-bundle` — CA bundle export with provenance and digest.
- `ec:hash-manifest` — canonical hash list of proof artifacts.
- `ec:artifact-signature` — signature bundles for artifacts.
- `ec:status-signature` — signed `status.json` proof status.

Provenance and translation

- Providers that produce differing payload shapes must publish a translator that emits EC-conformant payloads. Translators are implementation artifacts listed in provider descriptors.
