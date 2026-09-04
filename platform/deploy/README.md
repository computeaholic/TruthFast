# DEPLOYMENT STRUCTURE

This directory contains all deployment manifests and infrastructure definitions.
Each subdirectory has a single, unambiguous authority.

```
infra/        → cluster-level infrastructure (SPIRE, Istio, observability, policy)
services/     → application workloads
runtime/      → runtime control plane logic
router/       → ingress + routing layer
security/     → mTLS + zero-trust policies
governance/   → RBAC + policy definitions
gitops/       → ArgoCD definitions
overlays/     → environment overlays (dev/staging/prod)
```

## Source of truth rule

No manifest domain appears in more than one subtree.
If `deploy/infra/observability/` is the observability root, `deploy/observability/` must not exist.

## Evidence / runtime data

Runtime artifacts (proof evidence, debug captures, query results) are **never** stored
inside `deploy/`. They belong in `artifacts/` (git-ignored).
