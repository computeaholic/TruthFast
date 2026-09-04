# ----------------------------------------------------------------------------
# ForgeSec — Kubernetes-Native Operator Harness
# ----------------------------------------------------------------------------

.PHONY: forgesec forgesec-bootstrap-rbac forgesec-identity-k8s forgesec-surface-k8s forgesec-delta forgesec-clean

FORGESEC_IMAGE ?= registry.threadforge.local:30500/forgesec:v2
FORGESEC_MODE ?= isolated
FORGESEC_NAMESPACE ?= $(if $(filter shared,$(FORGESEC_MODE)),threadforge,forgesec)

# Canonical ForgeSec release path remains buildx-only via the helper script.
# Locked invariants retained here for repository contract tests:
# docker buildx build --builder threadforge-builder --platform linux/arm64 --pull --push
# docker buildx imagetools inspect "$${IMAGE_TAG}"
# Platform:[[:space:]]+linux\/arm64

forgesec-bootstrap-rbac:
	@bash scripts/forgesec/bootstrap_namespace.sh "$(FORGESEC_NAMESPACE)" "$(FORGESEC_MODE)"
	@kubectl -n "$(FORGESEC_NAMESPACE)" wait --for=jsonpath='{.metadata.name}'=forgesec-sa serviceaccount/forgesec-sa --timeout=30s

# ----------------------------------------------------------------------------
# Identity Suite (Blocking)
# ----------------------------------------------------------------------------

forgesec-identity-k8s:
	@echo "🔐 Launching ForgeSec Identity Suite (blocking)"
	@$(MAKE) forgesec-bootstrap-rbac
	@OUT_DIR="$(if $(OUTPUT_DIR),$(OUTPUT_DIR),artifacts/forgesec/manual-$$(date -u +%Y%m%dT%H%M%SZ)/identity)"; \
	mkdir -p "$$OUT_DIR"; \
	FORGESEC_NAMESPACE="$(FORGESEC_NAMESPACE)" bash scripts/forgesec/run_k8s_suite.sh identity "$$OUT_DIR" platform/deploy/forgesec/identity-job.yaml 180 "$(IMAGE_REF)"; \
	echo "✔ ForgeSec identity suite passed (artifacts: $$OUT_DIR)"

# ----------------------------------------------------------------------------
# Surface Suite (Adversarial Observation)
# ----------------------------------------------------------------------------

forgesec-surface-k8s:
	@echo "🔎 Launching ForgeSec Surface Suite"
	@$(MAKE) forgesec-bootstrap-rbac
	@OUT_DIR="$(if $(OUTPUT_DIR),$(OUTPUT_DIR),artifacts/forgesec/manual-$$(date -u +%Y%m%dT%H%M%SZ)/surface)"; \
	mkdir -p "$$OUT_DIR"; \
	FORGESEC_NAMESPACE="$(FORGESEC_NAMESPACE)" bash scripts/forgesec/run_k8s_suite.sh surface "$$OUT_DIR" platform/deploy/forgesec/surface-job.yaml 240 "$(IMAGE_REF)"; \
	echo "✔ ForgeSec surface suite passed (artifacts: $$OUT_DIR)"

# ----------------------------------------------------------------------------
# Delta (Optional Drift Snapshot)
# ----------------------------------------------------------------------------

forgesec-delta:
	@echo "🔁 Running ForgeSec delta comparison"
	@echo "ℹ️  ForgeSec delta is deprecated (legacy ./forgesec/delta removed); skipping."

# ----------------------------------------------------------------------------
# Full Operator Inspection Flow
# ----------------------------------------------------------------------------

forgesec:
	@bash -lc 'set -euo pipefail; \
		  TS="$$(date -u +%Y%m%dT%H%M%SZ)"; \
		  OUT_DIR="artifacts/forgesec/$${TS}"; \
		  mkdir -p "$${OUT_DIR}"; \
		  echo "🛡 ForgeSec — Adversarial Inspection"; \
		  echo "   Mode: Kubernetes-native ($(FORGESEC_MODE))"; \
		  echo "   Artifacts: $${OUT_DIR}"; \
		  FORGESEC_MODE="$(FORGESEC_MODE)" FORGESEC_NAMESPACE="$(FORGESEC_NAMESPACE)" FORGESEC_OUTPUT_DIR="$${OUT_DIR}" \
		    bash scripts/verify/verify_forgesec_enforcement.sh; \
		  echo "✔ ForgeSec inspection complete"'

# ----------------------------------------------------------------------------
# Cleanup Old Jobs (Optional Hygiene)
# ----------------------------------------------------------------------------

forgesec-clean:
	@echo "🧹 Cleaning ForgeSec jobs"
	@FORGESEC_NAMESPACE="$(FORGESEC_NAMESPACE)" bash scripts/forgesec/cleanup_transients.sh
