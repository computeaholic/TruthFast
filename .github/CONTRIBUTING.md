# Contributing to TruthFast

TruthFast accepts focused changes that preserve deterministic ownership,
identity-first authority, fail-closed behavior, and evidence truthfulness.

## Development setup

```bash
python3 -m venv .venv
./.venv/bin/python -m pip install -r requirements/dev.txt
```

Use a feature branch and pull request. Keep each commit scoped to one
architectural or defect class, add the smallest focused regression, and run the
smallest owning validation before broader local checks.

GitHub Actions proves repository truth only. Do not add cluster bootstrap,
runtime proof, Golden Boot, demos, Kubernetes mutation, Docker runtime
reconstruction, or host mutation to CI. Native runtime qualification is an
operator-controlled local operation.

Before opening a pull request, run the repository-level checks relevant to the
change, including `git diff --check`. Runtime-affecting changes must explicitly
state that the prior runtime-qualified SHA does not qualify the changed
executable tree.

Generated artifacts retain their canonical producer; change the producer rather
than hand-editing generated truth. Proof and verification code must not heal
producer-owned runtime state or convert missing mandatory evaluation into
`PASS`. Post-V1 research, including independent semantic replay and
replay/receipt certification, does not become current V1 authority through a
contribution alone; architectural promotion requires an accepted authority
change and appropriate qualification.
