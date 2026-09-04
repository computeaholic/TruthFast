# TruthFast System Model

This directory is descriptive/reference metadata for the V1 architecture. It
is not a new qualification authority. Exact-SHA qualification remains owned by
the supported execution, proof, audit, and Golden Boot paths.

The model separates source canonicality from release support:

- `SUPPORT_TIER` states whether a system is supported V1, secondary, advisory,
  experimental, compatibility, historical, or dead.
- `QUALIFICATION_SCOPE` states whether it participates in native V1
  qualification, a supported demo, secondary source only, operator tooling, or
  no current qualification.
- `REACHED_BY_SUPPORTED_V1_PATH` is system reachability, not an entrypoint
  registry. Exact Make targets exist only in `platform/config/support_contract.json`.

Files:

- `system_inventory.json` and `.csv`: 54-system ownership inventory.
- `edge_graph.json` and `system_edges.tsv`: 77 observed/proven relationships.
- `authority_mapping.json`: identity, authority, mutation, and trust boundary.
- `state_ownership.json`: state producer, consumer, and recovery ownership.
- `claim_evidence.json`: descriptive claim-to-evidence routing schema.
- `system_model.json`: schema metadata, counts, taxonomy, and current delta.
- `project_obligations.json`: GitHub issue, ADR, CI, branch, and current project
  obligation adjudication. It records project control state; it is not runtime
  or certification authority.
- `research_doctrine_matrix.json`: 35-law failed-assumption mapping. It records
  validated strengths, alignment, bounded validation pressure, watch state, and
  post-V1 boundaries; it does not create support obligations.

Historical immutable archaeology is retained in the private ThreadForge
engineering repository. The dated doctrine source is retained under
`reports/research/threadforge-failed-assumption-doctrine-20260828/`.
