# Security Policy

TruthFast is a defensive assurance reference architecture, not a
production-certified service. Security reports should identify the affected
source path, supported entrypoint, trust boundary, and the smallest known
reproduction. Do not include live credentials, private keys, or sensitive
runtime evidence in a public issue.

Use GitHub's private vulnerability-reporting or Security Advisory interface
when it is available. Otherwise contact the repository owner privately through
their GitHub profile before public disclosure.

The supported V1 boundary is defined by
`platform/config/support_contract.json`. Findings in secondary, experimental,
compatibility, or historical code should state whether a supported caller can
reach the affected path. Current limitations and non-claims are documented in
`docs/releases/CERTIFICATION_BASELINE.md` and
`docs/CANONICAL/TRUST_MODEL.md`.

Reference-profile credentials, local signing keys, and repository-managed key
custody demonstrate bounded controls; they are not production secret-management
guidance. Production adaptations should use appropriate managed or
hardware-backed key custody and independent operational controls where their
risk model requires them.

This policy describes a reporting channel. It does not create a bug bounty,
authorize testing against systems not owned by the reporter, or expand the
defensive testing boundary described by the repository.
