# TruthFast V1 Public Release Provenance

This clean-history repository is a TruthFast public-release candidate extracted
from the private [ThreadForge engineering repository](https://github.com/computeaholic/ThreadForge).

`PUBLIC_PROJECT_NAME=TruthFast`
`PUBLIC_REPOSITORY=computeaholic/TruthFast`
`SOURCE_ENGINEERING_REPOSITORY=computeaholic/ThreadForge`
`QUALIFIED_ENGINEERING_SOURCE_SHA=0ddae102badf2a93fe4fdb3934ad9a36db4c8c84`

It contains the source tree at:

`0ddae102badf2a93fe4fdb3934ad9a36db4c8c84`

That source revision is the exact executable revision qualified by the internal
ThreadForge V1 process. The qualification operations remain distinct runs,
including destructive reconstruction, proof, supported demos, controlled
outage evidence, tamper rejection, registry audit, canonical audit, and
repository verification. A matching source SHA does not make those operations
one execution.

This repository intentionally starts with fresh Git history. The engineering
repository retains its complete private history, issues, pull requests, and
historical forensic material. The clean export does not copy those private
records or generated runtime evidence. The detailed historical baseline is
retained for context in [CERTIFICATION_BASELINE.md](CERTIFICATION_BASELINE.md)
and remains bound to the SHA recorded inside that document.

The prior paper version DOI is [10.5281/zenodo.22240796](https://doi.org/10.5281/zenodo.22240796).
The current paper version 1.0.1 DOI is [10.5281/zenodo.22548396](https://doi.org/10.5281/zenodo.22548396),
with concept DOI [10.5281/zenodo.22240795](https://doi.org/10.5281/zenodo.22240795).
Qualification was an internal engineering process, not an independent audit,
third-party certification, or production-readiness assessment.

## Boundaries

- Native qualification is the single-host Kind reference profile.
- External PyPI, OCI, Helm, and Sigstore/Rekor prerequisites may be required by
  selected operations.
- The project makes no HA, universal portability, production key-custody, or
  independent semantic-replay claim.
- Reference credentials and keys are not production secret-management guidance.
- The public repository is kept private until the owner completes the separate
  publication gate.

## License provenance

Project-owned software material is licensed under the PolyForm Perimeter
License 1.0.1. Redistributed third-party material retains the notices and licenses recorded in
`THIRD_PARTY_NOTICES.md`, including the preserved Apache-2.0 license text.
