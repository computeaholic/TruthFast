# TruthFast Support Boundary

TruthFast V1 is a single-node Kind reference architecture. Supported native
entrypoints are defined by `platform/config/support_contract.json`; source that
is secondary, advisory, experimental, compatibility-only, or historical does
not acquire native V1 qualification by being present in the repository.

Use GitHub issues for reproducible defects and documentation gaps. Include the
source SHA, command, first failing leaf, exact error, and relevant artifact
path. Security-sensitive reports should follow `.github/SECURITY.md`.

Production deployment support, HA certification, multi-region operation,
hardware key custody, independent external audit, and universal Kubernetes
portability are outside the V1 support contract.
