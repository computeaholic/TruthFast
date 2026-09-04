# internal/

Purpose: implementation details and shared runtime internals.

What belongs here:

- internal packages
- shared helpers
- runtime data processing and model logic

What does not belong here:

- repository documentation
- proof outputs
- archived evidence
- top-level orchestration scripts

Owner: Core Implementation

Primary consumers:

- `platform/`
- `scripts/`
- `tests/`

Validation entry points:

- `pytest`
- `make validate-all`

Related architecture:

- `docs/architecture/16-Repository-Information-Model.md`
- `docs/architecture/03-Assurance-Capabilities.md`
