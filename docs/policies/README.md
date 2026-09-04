# policies/

Purpose: machine-readable policy registry and policy metadata.

What belongs here:

- policy registry files
- policy metadata
- policy classification source

What does not belong here:

- runtime evidence
- historical reports
- implementation code

Owner: Policy

Primary consumers:

- policy authors
- validation scripts
- reviewers

Validation entry points:

- `mkdocs build`
- `scripts/verify/verify_repository_topology.sh`

Related documents:

- `policy-registry.yaml`
