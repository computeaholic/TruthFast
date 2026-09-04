# REGISTRY_RETENTION_POLICY

## Purpose
Define non-destructive retention governance for canonical runtime and supporting registry inventory.

## Retention Periods
- runtime-active digests: retain indefinitely while referenced by manifests or running workloads.
- manifest-only digests: retain minimum 90 days after last live reference removal.
- registry-only digests: quarantine for 30 days before purge approval.

## Rollback Retention Rules
- retain at least 2 historical digests per critical control-plane repo (istio, spire, kyverno, kube-* mirrors).
- block purge for any digest referenced by rollback scripts, bootstrap paths, or release notes.

## Diagnostic Image Rules
- keep diagnostic utility images (curl, busybox, kubectl, runtime-ledger, forgesec) while any diagnostic workflow references remain.
- require explicit owner ack before downgrading diagnostic retention.

## Deprecated Image Policy
- deprecated images must be labeled with owner, deprecation date, and replacement digest.
- deprecated-but-retained entries are revalidated each hygiene cycle.

## Orphan Detection Policy
- orphan candidate criteria: not running, not manifest referenced, no workflow/make/script reference, no rollback linkage.
- orphaned candidates move to NEEDS_REVIEW then SAFE_TO_REMOVE only after two consecutive audit cycles.

## Registry Hygiene Cadence
- run this retention audit weekly.
- run full reference-trace plus signature verification before any purge wave.

## Provenance Expectations
- all retained operational images must be digest-pinned and traceable to repository source.
- unknown ownership (class I) must be assigned an owner within one audit cycle.

## Signature Expectations
- runtime and required manifest images must pass cosign verification.
- non-runtime retained images should be signed; unsigned entries are high-risk and cannot be promoted to rollback tier.

## Governance Guardrails
- no automatic purge in audit mode.
- no manifest mutation in audit mode.
- no workflow/proof semantic changes from retention classification tasks.
