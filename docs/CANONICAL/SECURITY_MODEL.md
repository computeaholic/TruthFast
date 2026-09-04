# Canonical Security Model

TruthFast enforces a layered security model across admission, runtime, supply chain, audit, and observability.

---

## Attack Surface and Enforcement Response

| Attack surface | Threat                                                           | Enforcement response                                                       |
| -------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Admission      | Pod without SPIFFE identity (default SA, sidecar opt-out)        | Kyverno deny, `failurePolicy: Fail`                                        |
| Admission      | Manually supplied identity socket or xDS bootstrap (`SPIFFE_ENDPOINT_SOCKET`, `GRPC_XDS_BOOTSTRAP`) | Identity-boundary VAP and Kyverno `deny-citadel-env-*` policies |
| Admission      | Ephemeral container injection (debugging bypass)                 | Kyverno `deny-ephemeral-containers`                                        |
| Admission      | External image pull (supply chain bypass)                        | Kyverno `enforce-image-digests`, `verify-image-signatures`                 |
| Admission      | Unsigned image                                                   | Kyverno cosign verify policy                                               |
| Control plane  | Scale Kyverno to 0 (disable admission)                           | VAP `protect-kyverno-availability` + RBAC                                  |
| Control plane  | Delete VAP (remove guard)                                        | RBAC: `threadforge-breakglass` group only                                  |
| Control plane  | Scale SPIRE to 0 (disable identity)                              | VAP `protect-spire-availability`                                           |
| Runtime        | Drift in running image digest                                    | `verify_runtime_images.sh` + `verify_no_external_runtime_images.sh`        |
| Runtime        | Lateral east-west traffic                                        | `verify_east_west_blocking.sh` + Istio AuthorizationPolicy                 |
| Runtime        | External egress                                                  | `verify_north_south_boundary.sh` + egress lockdown NetworkPolicy           |
| Runtime        | Unauthorized north-south path                                    | `test_deny.sh` — unauthorized path returns HTTP 403                        |
| Identity       | Istio CA fallback                                                | `verify_no_istio_ca_fallback.sh` — fails if Istio self-signed CA is active |
| Identity       | Trust root divergence                                            | `ca_integrity.json` — all three root hashes must match                     |
| Audit          | Audit-chain tampering                                            | SHA-256 hash chain + cosign-signed genesis and key registry; external anchoring is not claimed |
| Proof          | Artifact tamper                                                  | `verify_proof_artifacts.sh` — signature + digest + invariant re-check      |
| Proof          | Non-determinism                                                  | `make proof-determinism` — two-run comparison                              |

---

## Enforcement Layers

### Layer 1 — Admission (Kyverno + VAP)

First enforcement gate. Every pod admission is evaluated against identity, image, and policy rules before scheduling. `failurePolicy: Fail` means webhook unavailability blocks admission (fail-closed).

### Layer 2 — Mesh (Istio + SPIRE)

Runtime enforcement. mTLS peer authentication validates SPIFFE SVIDs on every connection. AuthorizationPolicies restrict allowed service-to-service paths. East-west traffic not matching an explicit ALLOW policy is denied.

### Layer 3 — Registry (cosign + internal registry)

Supply chain enforcement. Images must be digest-pinned, internally sourced, and cosign-signed. External pull paths are blocked at both admission (Kyverno policy) and verification (`verify_cluster_hermeticity.sh`).

### Layer 4 — Proof (prove_system.sh)

Verification layer. Runs after the runtime has been executing. Validates all enforcement claims against live runtime evidence. Fails closed if any check is ambiguous, skipped, or advisory-only.

---

## Namespace Enforcement Scope

| Namespace            | Admission enforced                                            | Mesh enforced                    |
| -------------------- | ------------------------------------------------------------- | -------------------------------- |
| `threadforge-test`   | Yes — all identity, sidecar, SA policies                      | Yes — mTLS + AuthorizationPolicy |
| `threadforge-system` | Yes                                                           | Yes                              |
| `default`            | Yes — `deny-default-namespace-workloads` blocks raw workloads | No active mesh policies          |
| `kube-system`        | No — TruthFast does not enforce in kube-system              | No                               |
| `spire-system`       | Protected by VAP (scale-to-0 blocked)                         | SPIRE operates outside mesh      |

---

## Fail-Closed Properties

- Webhook timeout → pod rejected (`failurePolicy: Fail`)
- Observability stack absent → proof fails as `MISSING_PREREQ`, not silently skipped
- SPIRE outage → new connection establishment fails (existing SVIDs continue until expiry)
- SPIRE scale-to-0 → denied by VAP (not reachable without break-glass)
- Proof script exit code non-zero → proof `FINAL: FAIL`
- Advisory-only failure in `STRICT_MODE` → CONTRACT_VIOLATION

---

## What is Not Enforced

See [Agent-Containment.md](../Agent-Containment.md#threat-boundary-and-non-claims) for the full list.

Key boundaries:

- Cluster-admin authority is not superseded
- `kube-system` is not under TruthFast admission enforcement
- External PKI roots are not blocked at the network level (only at the SPIFFE identity verification level)
