# Big Bang Profile (metadata only)

Profile id: `profile:bigbang:v1`
Author: TruthFast Architecture

## Summary

This profile maps Big Bang distribution components into TruthFast provider roles. It is metadata-only and contains capability bindings and provider descriptors; no implementation is included here.

Provider role mapping (representative)

- Identity Provider: `provider:bigbang/spire` — provides SVIDs and SPIRE bundle integration.
- Service Mesh: `provider:bigbang/istio` — data-plane topology and Envoy certificates (as observed).
- Registry: `provider:bigbang/harbor` — image registry metadata provider.
- Observability: `provider:bigbang/monitoring` — Grafana/Tempo/Loki ingestion capture.
- Signing: `provider:bigbang/cosign` — artifact signing and signature exposure.

Capability gaps

- Big Bang profile may lack lifecycle exercise automation for root rollout (see `verify_cert_rotation_continuity` lifecycle requirement).

Evidence translation

- Where provider artifacts differ in shape (e.g., cosign bundles vs HSM signatures), translators must emit EC-conformant payloads.
