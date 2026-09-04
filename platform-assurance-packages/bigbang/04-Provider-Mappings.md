# Provider Mappings — Big Bang

This document lists provider descriptors and their responsibilities for Big Bang.

Provider descriptors (representative)

- provider_id: provider:bigbang/spire
  - category: identity
  - capabilities: ["Identity"]
  - evidence_contracts: ["ec:identity-svid-capture","ec:ca-bundle"]

- provider_id: provider:bigbang/istio
  - category: service-mesh
  - capabilities: ["Topology","Runtime Sidecar Contract"]
  - evidence_contracts: ["ec:envoy-certs"]

- provider_id: provider:bigbang/harbor
  - category: registry
  - capabilities: ["Registry Governance","Runtime Images"]
  - evidence_contracts: ["ec:registry-manifest","ec:artifact-signature"]

- provider_id: provider:bigbang/cosign
  - category: signing
  - capabilities: ["Artifact Integrity"]
  - evidence_contracts: ["ec:artifact-signature","ec:status-signature"]

- provider_id: provider:bigbang/monitoring
  - category: observability
  - capabilities: ["Observability and Forensics"]
  - evidence_contracts: ["ec:trace-capture","ec:logs-index"]

Provider compatibility

- Each provider must declare compatibility with constitution version and EC schema version in its descriptor before implementation.
