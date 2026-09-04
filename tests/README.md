# tests/

Purpose: regression coverage and invariant verification.

What belongs here:

- pytest modules
- shell tests
- validation fixtures
- proof and policy regression coverage

What does not belong here:

- runtime source code
- long-lived evidence archives
- generated proof artifacts
- release documentation

Owner: Verification

Primary consumers:

- `make validate-all`
- developers adding or changing invariants

Validation entry points:

- `pytest`
- `make validate-all`

Related architecture:

- `docs/architecture/06-Proof-Architecture.md`
- `docs/architecture/16-Repository-Information-Model.md`
