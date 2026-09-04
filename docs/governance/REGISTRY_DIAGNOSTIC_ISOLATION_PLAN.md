# REGISTRY_DIAGNOSTIC_ISOLATION_PLAN

## Scope

Design-only isolation plan for diagnostic lineage. No enforcement or runtime mutation is implemented in this phase.

## Diagnostic Lineages In Scope

- ForgeSec det-\* lineage
- runtime-ledger-\* lineage
- pushgateway lineage
- temporary diagnostic images
- replay/test artifacts

## Isolation Model

- logical diagnostic namespace in governance metadata:
  - classification: REQUIRED_DIAGNOSTIC or OPTIONAL_FEATURE
  - runtime_eligible: false by default
- promotion boundary:
  - diagnostic lineages are denied runtime promotion unless explicit exception is approved

## Proposed Control Objectives

1. Namespace isolation

- mark diagnostic repositories with diagnostic-only ownership domain policy.

2. Promotion denial

- diagnostic-only artifacts cannot transition to runtime-eligible without exception workflow.

3. Runtime admission denial (design)

- future admission policy should reject diagnostic-only digests in runtime namespaces.
- current phase is observe-only; no admission change is applied.

4. Retention windows

- baseline retention for diagnostics: 30-90 days based on owner policy.
- incident-linked diagnostics may extend retention with incident reference.

5. Explicit approval requirements

- required fields for any diagnostic runtime exception:
  - incident/ticket id
  - expiry timestamp
  - owning team approver
  - platform approver
  - rollback impact assessment

## Family-Specific Guidance

- ForgeSec det-\*:
  - keep isolated as diagnostic experiment lineage.
  - deny runtime promotion by default.
- runtime-ledger-\*:
  - retain for audit forensics with bounded retention windows.
- pushgateway:
  - treat as observability diagnostic support; not runtime-critical by default.
- temporary replay artifacts:
  - mark as non-authoritative and time-bounded.

## Non-Goals

- no cleanup automation
- no purge execution
- no runtime behavior change
- no proof/determinism/SPIRE semantic change
