# Civ Engine — Intelligence-First Advisory Governance

**Classification**: Advisory Intelligence Layer
**Authority**: NONE
**Execution Capability**: NONE
**Status**: Implemented advisory reference component (Phase G3 constraints
verified; no production-readiness claim)

---

## What Civ Engine IS

The Civ Engine is an **intelligence-first advisory system** that produces decision provenance, counterfactual scenarios, and dormant enforcement intents. It operates under strict G3 mechanical enforcement constraints.

### Core Capabilities

1. **Decision Provenance (Phase D)**
   - Consumes cluster metrics (CPU, memory, denial rates, policy pressure)
   - Generates cryptographically attributable `DecisionRecord` objects
   - Explains WHY pressure exists (contributor analysis, time-windowed metrics)
   - Produces deterministic `provenance_hash` for audit replay

2. **Counterfactual Analysis (Phase E)**
   - Generates alternative scenarios (budget increase, load reduction, enforcement)
   - Computes projected outcomes for each scenario
   - Calculates `InertiaScore` to assess whether inaction is defensible
   - Provides stability assessment (why waiting may be valid)

3. **Dormant Intent Generation (Phase F)**
   - Produces `EnforcementIntent` artifacts marked `enforcement_prohibited=true`
   - Intents are **ready-but-non-executable** (activation blocked by `CIV_ENGINE` marker)
   - External enforcement systems consume intents, validate provenance, and decide
   - Civ NEVER activates intents (no execution path exists)

---

## What Civ Engine IS NOT

❌ **NOT an enforcer** — Civ produces recommendations, not enforcement actions
❌ **NOT a decision-maker** — All authority remains with external systems
❌ **NOT a scheduler** — No background processes, no event loops, no daemons
❌ **NOT an actuator** — No cluster mutations, no kubectl calls, no API writes
❌ **NOT autonomous** — Operator-initiated only, synchronous invocation
❌ **NOT binding** — All outputs marked `ADVISORY_ONLY` and `enforcement_prohibited=true`

---

## Supported Entry Points

These are the active reviewer-facing CIV surfaces in the repository:

- `make civ-status` - read-only status snapshot over the current value plane
- `make civ-identity-attribution-test` - identity attribution coverage and gap reporting
- `make civ-sbom-governance-test` - SBOM-to-image-to-identity correlation coverage
- `make civ-network-governance-test` - network signal coverage and attribution reporting
- `make civ-io-governance-test` - IO signal coverage and attribution reporting
- `make civ-identity-enrichment-test` - current-run identity enrichment artifact set
- `make civ-governance-stress-test` - combined CPU and memory CIV stress wrapper
- `make civ-authority-noncreation-test` - negative-capability audit for authority creation
- `make demo-civ` - public reviewer demo composed from CPU governance, memory governance, and identity attribution
- `make demo-authority-contrast` - supported authority-contrast demo built from the identity-enrichment path
- `make demo-security-boundary` - supported ForgeSec boundary demonstration

The CPU governance stress test inside `make demo-civ` is the active CIV
"IRONMAN DEMO" path. There is no standalone `make ironman` target.

All of the above are advisory-only and do not authorize execution.

---

## Architecture: Three-Layer Separation

```
┌─────────────────────────────────────────────────────────────┐
│ CIV ENGINE (Intelligence Layer) — ADVISORY ONLY             │
│ • Reads observability data                                   │
│ • Produces DecisionRecords, counterfactuals, dormant intents │
│ • Writes JSON/Markdown artifacts to disk                     │
│ • NO AUTHORITY, NO EXECUTION                                 │
└─────────────────────────────────────────────────────────────┘
                        ↓ (artifacts)
┌─────────────────────────────────────────────────────────────┐
│ OPTIONAL EXTERNAL AUTHORITY (outside Civ; not provided here) │
│ • Reads Civ artifacts from disk                              │
│ • Validates provenance_hash (cryptographic verification)     │
│ • Re-queries cluster state (Civ's inputs may be stale)       │
│ • Makes enforcement decision (manual approval OR policy)     │
│ • Invokes ActuatorCore.execute_plan() if approved            │
└─────────────────────────────────────────────────────────────┘
                        ↓ (execution request)
┌─────────────────────────────────────────────────────────────┐
│ ACTUATOR CORE (Execution Layer) — EXISTING                  │
│ • Constitutional governance gate                             │
│ • Policy governance gate                                     │
│ • Manual approval gate                                       │
│ • Executes kubectl/helm/tofu commands                        │
│ • Logs all actions to ledger                                 │
└─────────────────────────────────────────────────────────────┘
```

**Key Separation**: Civ advises → External enforcer decides → ActuatorCore executes

---

## G3 Compliance Guarantees

The Civ Engine is **100% compliant** with Phase G3 mechanical enforcement:

| Constraint                             | Civ Behavior                                                | Verification                              |
| -------------------------------------- | ----------------------------------------------------------- | ----------------------------------------- |
| ❌ No autonomous execution             | ✅ Operator-initiated only (function call or manual script) | Test: `test_no_kubernetes_client_imports` |
| ❌ No background daemons               | ✅ No schedulers, no event loops, no background workers     | Test: `test_no_threading_or_async`        |
| ❌ No provisioning authority           | ✅ No ManagedResources, no cloud provider credentials       | Test: `test_no_actuator_imports`          |
| ❌ No cluster API writes               | ✅ No `kubectl`, no Kubernetes client, no subprocess        | Test: `test_no_subprocess_imports`        |
| ❌ No bypass of admission/network/RBAC | ✅ No control plane access, writes to disk only             | Code inspection: No network imports       |
| ✅ Ledger-first                        | ✅ All decisions written to `artifacts/civ/decisions/`      | `ArtifactWriter`                          |
| ✅ Operator-initiated                  | ✅ External enforcer makes execution decisions (not Civ)    | No activation path in Civ code            |

**Verification**: covered by the repository's Civ and boundary verification
test suites. The exact suite size is intentionally not treated as a stable
architecture claim.

---

## Public API

### Phase D: Decision Provenance

```python
from runtime.civ import ProvenanceBuilder, ArtifactWriter

# Build decision from metrics
builder = ProvenanceBuilder(query_execution_context={...})
decision = builder.build_budget_pressure_decision(
    utilization_percent=85.0,
    denial_pressure=0.6,
    contributors=[...],
)

# Write to disk (JSON + Markdown + signature)
writer = ArtifactWriter()
result = writer.write_decision(decision)

# Result: {
#   "json_path": "artifacts/civ/decisions/{decision_id}.json",
#   "signature_path": "artifacts/civ/decisions/{decision_id}.json.sig",
#   "markdown_path": "artifacts/civ/decisions/{decision_id}.md"
# }
```

### Phase E: Counterfactual Analysis

```python
from runtime.civ import CounterfactualEngine

# Generate alternative scenarios
cf_engine = CounterfactualEngine()
counterfactuals = cf_engine.generate_counterfactuals(decision)

# Assess stability (is inaction defensible?)
inertia = cf_engine.compute_inertia_score(decision)

# Result:
# - counterfactuals.increase_budget (projected outcome)
# - counterfactuals.reduce_load (projected outcome)
# - counterfactuals.enforce_now (hypothetical outcome)
# - inertia.score (0.0 = unstable, 1.0 = stable)
# - inertia.interpretation (DEFENSIBLE | QUESTIONABLE | UNACCEPTABLE)
```

### Phase F: Dormant Intent Generation

```python
from runtime.civ import IntentBuilder, IntentValidator

# Build dormant enforcement intent
intent_builder = IntentBuilder()
intent = intent_builder.build_intent_from_decision(decision)

# Verify intent is truly dormant
validator = IntentValidator()
validator.validate_intent_is_dormant(intent)

# Result:
# - intent.enforcement_prohibited = True (immutable)
# - intent.activation_blocked_by = "CIV_ENGINE" (immutable)
# - intent.required_authority = "EXTERNAL_ONLY" (immutable)
```

---

## Outputs & Artifacts

All Civ outputs are written to `artifacts/civ/decisions/`:

1. **JSON Artifact** (`{decision_id}.json`)
   - Machine-readable full decision record
   - Includes all metrics, contributors, counterfactuals, recommendation
   - Cryptographically signed (Ed25519, Phase H)

2. **Signature Metadata** (`{decision_id}.json.sig`)
   - Ed25519 signature over JSON artifact
   - Key ID, signature, timestamp, signer identity
   - Enables cryptographic verification

3. **Markdown Artifact** (`{decision_id}.md`)
   - Human-readable explanation
   - Summary, metrics, contributors, recommendation
   - Includes provenance hash and signature verification

4. **Retention Metadata** (`{decision_id}.json.retention.json`)
   - Retention policy (90 days default)
   - Eligible for deletion date
   - Governance classification

---

## Immutable Fields (Enforced by Code)

The following fields are **immutable** (cannot be changed after creation):

### DecisionRecord

- `classification` → Always `"ADVISORY_ONLY"` (field with `init=False`, `default="ADVISORY_ONLY"`)
- `enforcement_prohibited` → Always `True` (field with `init=False`, `default=True`)

### EnforcementIntent

- `enforcement_prohibited` → Always `True` (field with `init=False`, `default=True`)
- `activation_blocked_by` → Always `"CIV_ENGINE"` (field with `init=False`, `default="CIV_ENGINE"`)
- `required_authority` → Always `"EXTERNAL_ONLY"` (field with `init=False`, `default="EXTERNAL_ONLY"`)

**Enforcement Mechanism**: Python dataclass with `init=False` + `default=<constant>` → field cannot be set during construction and has fixed default value.

---

## Determinism & Replay

### Provenance Hash Determinism

Same inputs → Same `provenance_hash` (SHA256 over inputs + metrics + contributors)

```python
decision1 = builder.build_budget_pressure_decision(...)
decision2 = builder.build_budget_pressure_decision(...)  # Same inputs

assert decision1.provenance_hash == decision2.provenance_hash
```

### Audit Replay

Given historical artifacts, an auditor can:

1. Load `{decision_id}.json` from disk
2. Verify signature using `{decision_id}.json.sig`
3. Re-query cluster metrics (if still available)
4. Regenerate decision with same inputs
5. Compare `provenance_hash` (should match)

**Result**: Cryptographic proof that decision was derived from stated inputs.

---

## Operator Warnings

### ⚠️ Stale Data Risk

Civ decisions are **time-windowed**. The decision reflects cluster state during `time_window` (e.g., last 60 minutes). State may have changed since decision generation.

**Required**: External enforcer MUST re-query cluster state before acting.

### ⚠️ Non-Binding Recommendations

All Civ outputs are **advisory-only**. Bad advice is safe (no execution path exists).

**Required**: Human operator or external enforcer validates recommendation before acting.

### ⚠️ Confidence Scores

Civ provides `recommendation.confidence` (0.0 – 1.0). Low confidence = uncertain recommendation.

**Required**: Operators should not act on low-confidence recommendations without additional validation.

---

## Test Coverage

### Positive Tests (Functionality)

- **Phase D**: 21 tests (decision provenance, builder, writer)
- **Phase E**: 20 tests (counterfactual engine, inertia scoring)
- **Phase F**: 24 tests (dormant intent generation, validation)
- **Phase H**: 56 tests (signing, retention, identity gating)

**Total**: 121 tests, all passing ✅

### Negative Tests (Boundary Verification)

- ❌ No Kubernetes client imports (static analysis)
- ❌ No subprocess/os.system calls (static analysis)
- ❌ No threading/asyncio imports (static analysis)
- ❌ No actuator imports (static analysis)
- ❌ No database write keywords (static analysis)
- ❌ No write/execute methods (runtime inspection)
- ❌ Immutable fields cannot be modified (pytest)
- ❌ Provenance hash is deterministic (pytest)

**Total**: 15+ negative verification tests ✅

---

## Documentation

### Reviewer-Grade Documentation

- **[CANONICAL/ARCHITECTURE.md](../../../docs/CANONICAL/ARCHITECTURE.md)** — Cross-system architecture and authority boundaries
- **[CANONICAL/SECURITY_MODEL.md](../../../docs/CANONICAL/SECURITY_MODEL.md)** — Threat model and enforcement assumptions
- **[CANONICAL/PROOF_MODEL.md](../../../docs/CANONICAL/PROOF_MODEL.md)** — Proof orchestration and verification semantics
- **[ARCHITECTURE/17-CONCEPT-INDEX.md](../../../docs/architecture/17-Concept-Index.md)** — Canonical concept ownership map

---

## Integration Boundary (External to Civ)

### Optional External Enforcer

An external authority may consume Civ artifacts and independently:

1. Read Civ artifacts from `artifacts/civ/decisions/` and `artifacts/civ/intents/`
2. Validate `provenance_hash` (cryptographic verification)
3. Re-query cluster state (Civ's inputs may be stale)
4. Make enforcement decision (manual approval OR automated policy)
5. Invoke `ActuatorCore.execute_plan()` (respects all governance gates)

**Constraints**:

- ✅ MUST invoke ActuatorCore (no kubectl bypass)
- ✅ MUST re-validate cluster state (Civ's data may be stale)
- ✅ MUST respect governance gates (constitutional, policy, approval)
- ❌ MUST NOT modify Civ artifacts (read-only consumption)
- ❌ MUST NOT bypass Phase G3 enforcement (all constraints still enforced)

No external enforcer is part of the Civ component or the supported native demo
surface. Any consumer remains outside Civ's authority boundary.

### Optional Service Integration

If a future external consumer needs HTTP access to Civ, that integration must:

1. FastAPI service with mTLS-enforced endpoints
2. Istio VirtualService with SPIFFE ID enforcement
3. NetworkPolicy: Egress to observability databases ONLY (no control plane)
4. RBAC: SELECT-only permissions on `value_plane.*`
5. ServiceAccount: `civ-service` (no write permissions)
6. Endpoints return JSON (no cluster mutations)

**Constraints**:

- ✅ All endpoints advisory-only (no executory endpoints)
- ✅ NetworkPolicy required (egress to observability only)
- ✅ RBAC required (SELECT-only)
- ❌ NO cluster API writes (advisory responses only)

No Civ service API is part of the current supported native surface.

---

## FAQ

### Q: Can Civ Engine execute actions?

**A**: No. Civ has NO execution capability. All enforcement remains external (either human operator or external enforcer service).

### Q: Can Civ write to authority tables?

**A**: No. Civ has SELECT-only permissions on `value_plane.*` (observability data). No write path exists.

### Q: Can Civ bypass Phase G3 enforcement?

**A**: No. Civ has no cluster API access, no kubectl, no subprocess calls, no actuator imports. All G3 constraints remain enforced.

### Q: What happens if Civ produces wrong recommendation?

**A**: Bad advice is safe. Civ has no execution path, so wrong recommendations cannot cause cluster mutations. External enforcer validates and decides.

### Q: How do I know Civ's data is fresh?

**A**: Check `time_window` in DecisionRecord. If stale, external enforcer MUST re-query cluster state before acting.

### Q: Can Civ be deployed as a service?

**A**: A service integration is not part of the current supported native
surface. Any future integration would remain advisory-only, with
NetworkPolicy and SELECT-only RBAC constraints.

### Q: Who has authority to act on Civ recommendations?

**A**: Human operators OR external enforcer service. Civ has NO authority, NO execution capability.

---

## Status

**Phase G3 Compliance**: ✅ **VERIFIED** (100% compliant, 121 tests passing)
**Production Readiness**: Not claimed; this document describes a bounded
advisory reference component, not a production deployment certification.
**Authority**: ❌ **NONE** (advisory-only)
**Execution Capability**: ❌ **NONE** (external enforcement only)

**Verification**: Repository Civ and boundary verification surfaces
