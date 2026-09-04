# Governance

This document defines governance for constitutional artifacts, versioning, ADRs, and owner responsibilities.

Versioning policy

- Constitution version: increment on ADR-approved constitutional changes.
- Evidence Contract versions: semantic versioning; incompatible changes require migration ADR.

Architectural review process

- Changes to constitutional objects require an ADR, two reviewers from architecture owners, and a public review window.

Evidence Contract and Claim evolution

- Backwards-compatible EC changes: minor version increment and owner sign-off.
- Breaking EC change: ADR + migration plan + compatibility translator.

Provider and Profile compatibility

- Providers must declare compatibility ranges with constitution and profile versions.
- Profiles must pass static validation before being used in migrations.

Deprecation policy

- Deprecation requires ADR and 2 release cycles notice; maintain translators where possible.

ADR requirements

- All constitutional changes must be recorded as ADRs under `ADR/` and include rationale, impact, and migration path.

Owners

- Each capability, claim, and EC must list an owner entry in the Governance tracker (team or person).
