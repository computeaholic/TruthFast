# Canonical Trust Model

TruthFast enforces a single authoritative trust chain anchored at SPIRE.

---

## Trust Root

**Root**: SPIRE
**Issuance path**: SPIRE node attestation → SPIRE CA → istiod intermediate (via CSR) → workload SVIDs
**Runtime identity**: SPIFFE SVIDs (`spiffe://identity.threadforge.local/ns/*/sa/*`)

```
SPIRE root CA  (trust root)
  └── spire-csr-intermediate  (istiod signs via SPIRE CSR path)
        └── workload SVIDs  (issued per-workload on injection)
              └── Envoy mTLS  (peer identity verified via SPIFFE)
```

---

## Hybrid Model

istiod acts as the wire-level certificate signer for protocol compatibility (Istio SDS). However, istiod's own signing key is not self-generated — it is issued by SPIRE via the CSR path. This means SPIRE remains the trust root even though istiod is the immediate issuer.

The gateway (`spire-csr-intermediate`) uses the SPIRE CSR path directly, without istiod mediation.

**Self-signed Istio CA**: `istio_ca_secret_in_use: false` — the Istio CA secret exists as a bootstrap artifact but is not active. Any admission of workloads relying on the Istio self-signed CA is a trust root violation and proof fails with `no_istio_ca_fallback: FAIL`.

---

## Cluster-Admin Boundary

Cluster-admin is the ultimate Kubernetes authority. TruthFast does not claim to supersede it.

TruthFast enforces:

- **Visibility**: the bounded audit and proof paths record the enforcement
  decisions required by their declared claims
- **Auditability**: hash-chained audit log with cosign-signed genesis and key
  registry evidence
- **Break-glass friction**: modifications to control-plane components require `threadforge-breakglass` RBAC group membership
- **Fail-closed enforcement**: admission-webhook enforcement paths use
  `failurePolicy: Fail`; other boundaries retain their own explicit denial
  contracts

A cluster-admin with direct API server access can modify or remove TruthFast controls. This is the inherent Kubernetes trust model. TruthFast makes such actions visible and auditable but cannot prevent them at the cluster-admin boundary.

---

## Trust Invariants (proof-validated)

| Invariant                                  | Verified by                                 |
| ------------------------------------------ | ------------------------------------------- |
| SPIRE-authorized runtime root is coherent across SPIRE/Istio/Envoy | `ca_integrity.json` — selected root hashes match |
| No Istio CA fallback                       | `verify_no_istio_ca_fallback.sh`            |
| Gateway CA source is SPIRE                 | `verify_gateway_ca_source.sh`               |
| Trust root immutability across proof run   | `verify_trust_root_immutability.sh`         |
| Node trust boundary intact                 | `verify_node_trust_boundary.sh`             |
| SPIFFE SVIDs issued for all mesh workloads | `validate_spiffe_identity.sh`               |
| Envoy validates peer SPIFFE identity       | `validate_envoy_identity.sh`                |

---

## Key Rotation Model

SPIRE performs active root rollover and may expose multiple certificates while a
bundle is transitioning. The proof selects the active authority from the
authoritative SPIRE lifecycle state and keeps the issuance root, leaf issuer,
and bundle membership as separate facts. A legitimate multi-certificate bundle
is not itself a contract violation; ambiguous or unauthorized root selection is.
The selected runtime authority must remain coherent across SPIRE, Istio, and
Envoy at proof time.

Certificate rotation continuity is separately validated: `verify_cert_rotation_continuity.sh` confirms that live SDS cert rotation produces a changed serial number at single-replica scale.

SPIRE is also the explicit producer of successor trust roots. TruthFast does
not generate, write, or publish successor roots. When `prepare_due` becomes
true, TruthFast witnesses the SPIRE-prepared successor through lifecycle
evidence and fails closed if that external producer has not published the
required state. Before that window, `ACTIVE_ONLY` is a valid state and does not
claim that a successor is already due.

TruthFast observes and validates that state; it does not synthesize successor roots inside the proof path.

The qualified V1 evidence establishes successor publication, acceptance by
load-bearing Istio/Envoy consumers, and current-lineage convergence. It does not
independently establish behavioral rejection of every retired predecessor at
every relying consumer. Configuration replacement or absence from the selected
bundle must not be described as universal relying-party revocation evidence.
