# Constitutional Claims

Claims are the atomic, declarative assertions the architecture uses to certify behavior. Each claim must be uniquely identified and owned.

Claim record fields

- `id` (string) — unique claim id `claim.<capability>.<name>`
- `purpose` (string)
- `invariant` (single declarative sentence)
- `failure_semantics` (string)
- `evidence_contracts` (list of `ec:` ids)
- `proofs` (list of native proof script names)
- `confidence` (low/medium/high)
- `cert_impact` (which certifications require this claim)
- `relations` (depends-on / related)

Claims must be registered and traceable to proofs in the native implementation.
The [Concept Index](17-Concept-Index.md), repository manifest, and proof phase
contracts provide the active ownership and execution mappings.
