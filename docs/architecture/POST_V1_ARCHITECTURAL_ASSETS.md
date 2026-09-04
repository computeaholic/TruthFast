# Post-V1 Architectural Assets

These opportunities are research/product directions extracted from existing
TruthFast mechanisms. They are not V1 features, blockers, or release claims.

| Direction | Priority | Why it exists | TruthFast assets | First experiment | Value mechanism | Research value | Commercial optionality | Extraction difficulty | Home |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Portable evidence graph / assurance engine | `VERY_HIGH` | Reviewers need to ask why a claim is true, who owns it, and what breaks it | System/edge model, guarantee graph, source/run binding, signed evidence | Export one proof DAG to a stable schema and answer “why is identity fail-closed PASS?” | Portable claim justification and assurance interoperability | High | High | Medium | V2 or separate SDK |
| Executable reviewer assurance kit | `VERY_HIGH` | Cold reviewers need bounded scenarios with understandable evidence | Four demos, outage proof, tamper proof, proof verifier | Package one identity-outage scenario plus evidence viewer | Faster technical diligence and training | High | High | Medium | Separate product surface |
| Runtime digest reconciliation service | `VERY_HIGH` | Digest alias, index, child, and runtime imageID truth generalizes beyond one cluster | Canonical inventory, pin maps, registry/runtime verifiers | Reconcile a second registry/runtime using explicit aliases | Supply-chain drift detection and repair ownership | Medium | Very high | Medium | Separate service |
| Identity-to-authority mediation | `VERY_HIGH` | Proxy/SVID/capability/AAS patterns are reusable when fail-closed defaults are preserved | XFCC boundary, SPIFFE identity, `UNCLAIMED` default, capability resolver | Extract pure adapters and prove forged/missing identity denial in two frameworks | Reusable identity-first authorization boundary | High | High | Medium | Separate library plus V2 integration |
| CIV causal assurance lab | `HIGH` | Deterministic provenance, counterfactuals, inertia, and recommendation need a non-authoritative research home | DecisionRecord, analytical projection, replay/tamper tests, ClickHouse lenses | Publish a minimal replay corpus while keeping activation impossible | Causal review and decision provenance research | Very high | Medium | Medium | Separate research project |
| Portable Golden Boot | `UNRANKED` | Exact-SHA reconstruction is valuable beyond one persistent host | Stage markers, producer graph, host contract, source binding | Decouple local registry/trust and test a second supported host profile | Reproducible reference-system qualification | Medium | High | High | V2 |
| External audit anchoring | `UNRANKED` | Local chains prove integrity but lack an external immutable root | Audit chain, proof hashes/signatures, completion identity | Anchor one proof/audit root externally and verify replay | Independent timestamp/immutability boundary | Medium | High | Medium | V2 integration |
| HA and backup qualification | `UNRANKED` | Current single-node/key/state ownership is the largest operational boundary | State ownership map, SPIRE/data planes, Golden Boot | Define RPO/RTO and prove a bounded SPIRE/data restore | Operational survivability evidence | Medium | High | High | V2 |

## Portable Evidence Graph Boundary

The current model can express claim, system, identity, authority, verifier,
runtime observation, positive/negative test, evidence artifact, source SHA,
signature/hash, and conclusion relationships. In V1 this graph remains
descriptive/reference metadata. It neither executes policy nor qualifies a
release.

## Stop Boundary

Do not add autonomous actuation, CIV activation, HA, multi-cluster support, or
the evidence engine to V1. Each direction requires a separate architecture and
qualification decision.
