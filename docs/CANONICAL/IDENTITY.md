# Canonical Identity Model

TruthFast identity is SPIFFE/SPIRE authoritative.

## Enforced identity invariants

- Workload identity delivery is required.
- Live in-mesh traffic must be proven alongside workload SPIFFE evidence.
- No Istio CA fallback is allowed.
- Gateway CA source must remain SPIRE-authoritative.
- Workload SPIFFE IDs use the `identity.threadforge.local` trust domain.
- The selected SPIRE-authorized runtime lineage must remain coherent across
  SPIRE/Istio/Envoy. Active authority, issuance authority, and bundle
  membership are separate facts during legitimate rollover.
- Node trust boundary checks must pass.

## Enforcing scripts

- `scripts/verify/validate_spiffe_identity.sh`
- `scripts/verify/validate_envoy_identity.sh`
- `scripts/verify/verify_no_istio_ca_fallback.sh`
- `scripts/verify/verify_gateway_ca_source.sh`
- `scripts/verify/verify_trust_root_immutability.sh`
- `scripts/verify/verify_node_trust_boundary.sh`

## Evidence

- `artifacts/spiffe_validation.json`
- `artifacts/envoy_identity_validation.json`
- `artifacts/proof/latest/ca_integrity.json`
- `artifacts/proof/latest/gateway_ca_source.json`
