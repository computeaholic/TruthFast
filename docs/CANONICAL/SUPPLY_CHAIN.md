# Canonical Supply Chain Model

TruthFast requires digest-pinned and trusted runtime image behavior.

## Required supply-chain outcomes
- Manifest image digests are enforced.
- Runtime images stay within approved/internal boundaries.
- Signature verification executes for scoped images.
- No unapproved external pull path passes verification.

## Enforcing scripts
- `scripts/verify/enforce_image_digests.sh`
- `scripts/verify/verify_no_external_runtime_images.sh`
- `scripts/verify/verify_signatures.sh`
- `scripts/tests/test_no_external_pull.sh`
- `scripts/verify/verify_cluster_hermeticity.sh`
