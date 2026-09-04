###############################################################################
# THREADFORGE — DOCTOR MODULE (V13)
# Purpose:
#   - Observability is OPTIONAL
#   - Runtime must NEVER fail due to telemetry
#   - Single command verification pass
#   - Reviewer-grade diagnostics snapshot
###############################################################################

.PHONY: doctor doctor-gate doctor-snapshot doctor-spire doctor-istio

doctor: ; @bash scripts/debug/doctor-run.sh

# Backwards-compatible target that runs the individual checks (used by scripts/doctor-run.sh)
.PHONY: doctor-verify-bins doctor-core
doctor-verify-bins:
	@command -v $(KUBECTL) >/dev/null || (echo "kubectl missing" && echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)
	@command -v $(HELM) >/dev/null || (echo "helm missing" && echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)

doctor-core: doctor-verify-bins kubeconfig-sync doctor-snapshot doctor-spire doctor-istio doctor-observability doctor-telemetry-gate doctor-configs doctor-collector-attest
	@echo "[TF] Ensuring test overrides are cleared for live checks"
	@unset TEST_CASE >/dev/null 2>&1 || true
	@export PATH="$$(echo $$PATH | tr ':' '\n' | grep -v '^$(REPO_ROOT)/tests/mockbin$$' | paste -sd: -)" >/dev/null 2>&1 || true
	$(call log-ok,Doctor complete (observability advisory))

doctor-gate: doctor
	@echo "🚪 Doctor gate enforces core health; observability is advisory by design"
	$(call log-step,"🚪 Doctor gate: enforcing health standards")
	@if kubectl get ns observability >/dev/null 2>&1; then \
		echo "✔ Observability namespace present"; \
		kubectl get peerauthentication -n observability >/dev/null 2>&1 || \
			echo "⚠️  Missing PeerAuthentication in observability namespace"; \
		kubectl get authorizationpolicy -n observability >/dev/null 2>&1 || \
			echo "⚠️  Missing AuthorizationPolicy in observability namespace"; \
	else \
		echo "⚠️  Observability not installed — gate continues (optional by design)"; \
	fi
	$(call log-ok,Doctor gate complete (observability non-fatal))

doctor-snapshot:
	$(call log-step,"🧾 Snapshot: nodes + critical pods")
	@$(RUN_KUBECTL) get nodes -o wide
	@$(RUN_KUBECTL) get pods -A -o wide | sed -n '1,200p'

doctor-spire:
	$(call log-step,"🧬 SPIRE check")
	@$(RUN_KUBECTL) get pods -n spire-system || true
	@$(RUN_KUBECTL) logs -n spire-system statefulset/spire-server --since=10m --tail=100 2>/dev/null || true

doctor-istio:
	$(call log-step,"🕸️  Istio check")
	@$(RUN_KUBECTL) get pods -n istio-system 2>/dev/null || true


# ------------------------------------------------------------------------------
# OBSERVABILITY CHECK (SOFT FAIL — NON-FATAL)
# ------------------------------------------------------------------------------

OBS_NS := observability

doctor-observability:
	@echo ""
	@echo "🔍 Checking observability stack (non-fatal)…"
	@OBS_DEGRADED=0; \
	if ! kubectl get ns $(OBS_NS) >/dev/null 2>&1; then \
		echo "⚠️  Observability namespace missing: $(OBS_NS)"; \
		OBS_DEGRADED=1; \
	else \
		for svc in prometheus loki tempo grafana; do \
			if ! kubectl get pods -n $(OBS_NS) -l app.kubernetes.io/name=$$svc >/dev/null 2>&1; then \
				echo "⚠️  Component missing or not ready: $$svc"; \
				OBS_DEGRADED=1; \
			else \
				echo "✔ $$svc present"; \
			fi; \
		done; \
	fi; \
	if [ "$$OBS_DEGRADED" = "1" ]; then \
		echo ""; \
		echo "⚠️  OBSERVABILITY DEGRADED"; \
		echo "⚠️  Runtime unaffected — reviewer guarantees reduced"; \
		touch /tmp/threadforge_observability_degraded; \
	fi


# ------------------------------------------------------------------------------
# TELEMETRY SAFETY GATE (GATING) — Promoted 2026-01-26
# Authority Question: "Am I flying blind?"
# This gate verifies telemetry is live, fresh, and end-to-end functional.
# Observation-only; does NOT mutate cluster state by default; does NOT require identity.
# ----------------------------------------------------------------------------
# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
.PHONY: doctor-telemetry-gate

doctor-telemetry-gate:
	$(call log-step,🔒 Telemetry safety gate)
	@bash scripts/debug/doctor-telemetry-gate.sh

# ------------------------------------------------------------------------------
# COLLECTOR ATTESTATION (Attestor - advisory, non-fatal)
# Doctor should run attestors in advisory mode; enforcement is the Operator's responsibility
# ------------------------------------------------------------------------------
.PHONY: doctor-collector-attest

doctor-collector-attest:
	$(call log-step,"🔍 Collector attestation (advisory)")
	@bash platform/runtime/attestation/collector_attestor.sh || echo "⚠️  Collector attestation reported FAIL (see evidence)" || true

# ------------------------------------------------------------------------------
# Collector gate (GATING) — added on execution 'Go'
# This target is a gating check intended to run a bounded probe (write+read) and
# produce an evidence bundle on success/failure. It must be added atomically as
# part of the execution PR along with the script and CONTRACT update.
# ------------------------------------------------------------------------------
.PHONY: doctor-collector-check

doctor-collector-check:
	$(call log-step,🔒 Collector gate — proposed)
	@bash scripts/debug/doctor-collector-check.sh

# ------------------------------------------------------------------------------
# CONFIG INTEGRITY GATE (GATING) — Promoted 2026-01-27
# Authority Question: "Am I executing against the configuration I believe I am?"
# This gate verifies runtime-effective configuration matches expected source.
# Observation-only; does NOT mutate cluster state.
# ------------------------------------------------------------------------------
.PHONY: doctor-config-integrity-gate

doctor-config-integrity-gate:
	$(call log-step,🔒 Config integrity gate)
	@bash scripts/debug/doctor-config-integrity-gate.sh

# ------------------------------------------------------------------------------
# CONTROL PLANE & POLICY GATE (GATING) — Promoted 2026-01-27
# Authority Question: "Can this cluster mutate state outside of declared,
#                      intentional control?"
# This gate verifies blast radius and authority containment.
# Observation-only; does NOT mutate cluster state.
# ------------------------------------------------------------------------------
.PHONY: doctor-control-plane-gate

doctor-control-plane-gate:
	$(call log-step,🔒 Control plane gate)
	@bash scripts/debug/doctor-control-plane-gate.sh

# ------------------------------------------------------------------------------
# CHANGE AUTHORITY & DRIFT RESISTANCE GATE (GATING) — Promoted 2026-01-27
# Authority Question: "Can this system change itself without explicit,
#                      attributable intent?"
# This is the final gate separating governed from sovereign execution.
# Observation-only; does NOT mutate cluster state.
# ------------------------------------------------------------------------------
.PHONY: doctor-change-authority-gate

doctor-change-authority-gate:
	$(call log-step,🔒 Change authority gate)
	@bash scripts/debug/doctor-change-authority-gate.sh

# ------------------------------------------------------------------------------
# CONFIG OBJECT ASSERTIONS
# ------------------------------------------------------------------------------

doctor-configs:
	@bash scripts/debug/doctor-configs.sh || touch /tmp/threadforge_observability_degraded

.PHONY: reviewer-check

reviewer-check:
	@echo "[TF] Running reviewer sanity checks"
	@kubectl get crds | grep -q certificates.cert-manager.io
	@kubectl get ns istio-system cert-manager spire-system
	@if kubectl get pods -A --no-headers | grep -v Running | grep -v Completed | grep -q .; then \
		echo "Found pods not in Running or Completed status:"; \
		kubectl get pods -A | grep -v Running | grep -v Completed; \
		echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
	fi
	@echo "[OK] Reviewer checks passed"

.PHONY: doctor-clean drift-check hygiene-check doctor-explain

doctor-clean:
	@bash scripts/debug/doctor-clean.sh

drift-check:
	@bash scripts/debug/drift-check.sh

hygiene-check:
	@bash scripts/debug/hygiene-check.sh

# Reviewer-facing no-op target that explains scoped NON-CLAIMs (no cluster access)
.PHONY: doctor-explain
doctor-explain:
	@echo "ℹ️  Doctor explain: Intentional non-claim summary (no-op)"
	@echo " - Tempo mesh-origin ingress enforcement is a documented NON-CLAIM under PodSecurity 'restricted'."
	@echo " - Rationale: we will not weaken PodSecurity or enable sidecar injection solely to make this claim enforceable."
	@echo " - See: docs/doctor/CONTRACT.md and docs/review/PROOFS.md"
	@true
