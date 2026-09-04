# Provider Architecture

Providers are implementation artifacts that produce Evidence Contracts, advertise capabilities, and execute platform-specific collection tasks. Providers are explicitly not constitutional; they are replaceable implementations.

Provider categories

- Identity Providers (SPIRE-like)
- Registry Providers (Harbor/Registry APIs)
- Signing Providers (cosign, HSM-backed signers)
- Observability Providers (Tempo/Loki/Prometheus collectors)
- Platform Providers (k8s distro specifics: Big Bang, OpenShift, EKS)

Provider descriptor

- `provider_id`: unique identifier
- `category`: capability category
- `version`: semantic version
- `capabilities`: capability IDs the provider can produce
- `evidence_contracts`: EC ids the provider produces
- `endpoints`: APIs or CLI invocations

Provider lifecycle

- Install/enable
- Advertise capabilities and ECs
- Produce evidence during invocations
- Support upgrades and deprecation with compatibility declarations

Evidence production

- Providers must produce ECs conforming to the base schema. Provider-specific payloads go into `payload` but base fields must be present.

Compatibility

- Providers must declare compatibility ranges for constitution versions, capability sets, and profiles.

Provider replacement

- A provider may be replaced by advertising the same capability and EC outputs. Migration must preserve proof continuity where required by policy.
