# releases/

Purpose: certification baselines and release-candidate evidence.

What belongs here:

- certification baselines
- release-specific evidence
- release readiness documents

What does not belong here:

- runtime code
- proof outputs outside release context
- private engineering forensics that are not part of this clean source export

Owner: Release Engineering

Primary consumers:

- release reviewers
- certification workflows
- auditors

Validation entry points:

- `mkdocs build`
- `scripts/verify/verify_repository_topology.sh`

Related documents:

- `CERTIFICATION_BASELINE.md`
- `PUBLIC_RELEASE_PROVENANCE.md`
