# TruthFast Public Identity Reconciliation

This release uses one external project identity:

```text
PUBLIC_PROJECT_NAME=TruthFast
PUBLIC_REPOSITORY=computeaholic/TruthFast
PRIVATE_ENGINEERING_LINEAGE=computeaholic/ThreadForge
QUALIFIED_ENGINEERING_SOURCE_SHA=0ddae102badf2a93fe4fdb3934ad9a36db4c8c84
```

TruthFast is the clean-history public reference distribution. ThreadForge is
the private engineering and provenance lineage. The two repositories
intentionally have different Git histories and commit hashes.

ThreadForge references remain only where they preserve provenance, identify
runtime-owned identifiers or paths, or retain historical architecture and
evidence truth. Current public project names, repository URLs, release links,
and reviewer-facing descriptions use TruthFast.

The non-native GitOps and verification examples also use the TruthFast
repository as their source URL. Runtime namespaces, trust domains, environment
variables, and other contract identifiers retain `threadforge` because they
are executable names rather than public branding.

This document records the boundary; it does not rename executable package,
namespace, trust-domain, service, or compatibility identifiers whose names are
part of the supported runtime contract.
