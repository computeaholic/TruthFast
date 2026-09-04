# ==============================================================================
# THREADFORGE — Umbrella Makefile (V13 — Identity Plane First)
# Cluster Bootstrap · Infra Bring-up · Runtime Launch
# Reference Pattern · Deterministic · Review-Grade
# ==============================================================================

override SHELL := $(CURDIR)/scripts/lib/make-shell.sh

# Auto-detected runtime (execution happens on the Ubuntu VM).
TF_RUNTIME := $(shell if [ -f /etc/os-release ] && grep -qi '^ID=ubuntu' /etc/os-release; then echo linux-vm; else uname -s | tr '[:upper:]' '[:lower:]'; fi)

# Legacy host MODE normalization
# MODE=macos/vm/linux/attached was an old host-selector. Execution is on the Ubuntu VM.
# Keep MODE=strict (doctor) and ForgeSec identity MODE values (authorized/unauthorized/unauthenticated) intact.
ifeq ($(MAKELEVEL),0)
ifneq ($(filter macos vm linux attached,$(MODE)),)
$(info [TF] WARNING: legacy MODE='$(MODE)' ignored; runtime=$(TF_RUNTIME))
override MODE :=
endif

$(info 🌐 ThreadForge Umbrella Makefile Loaded (runtime=$(TF_RUNTIME)))
endif

MAKEFLAGS += -Rr

# ------------------------------------------------------------------------------
# CANONICAL REPO ROOT (DO NOT GUESS IN SUB-MAKEFILES)
# ------------------------------------------------------------------------------
REPO_ROOT := $(shell git rev-parse --show-toplevel 2>/dev/null)
ifeq ($(REPO_ROOT),)
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
endif

export ROOT := $(REPO_ROOT)

# ------------------------------------------------------------------------------
# IDENTITY TRUST DOMAIN — canonical value; export so all recipe shells inherit.
# A clean-machine engineer can just run 'make proof' without any manual export.
# ------------------------------------------------------------------------------
SPIFFE_TRUST_DOMAIN ?= identity.threadforge.local
export SPIFFE_TRUST_DOMAIN

BOOTSTRAP_MODE ?= strict
export BOOTSTRAP_MODE

# Execution profile separation:
# - local: authoritative operator/runtime semantics (default)
# - ci: disposable replay orchestration (must not invoke local destructive flows)
THREADFORGE_EXECUTION_PROFILE ?= local
export THREADFORGE_EXECUTION_PROFILE

# ------------------------------------------------------------------------------
# SSH (DETERMINISTIC, NON-INTERACTIVE)
# ------------------------------------------------------------------------------
SSH_USER        ?= threadforge
SSH_HOST        ?= 192.168.64.5
SSH_KEY         ?= $(HOME)/.ssh/threadforge_ed25519
SSH_OPTS        := -i $(SSH_KEY) -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
SSH             := ssh $(SSH_OPTS) $(SSH_USER)@$(SSH_HOST)

SUDO            := sudo -n

# ------------------------------------------------------------------------------
# COLORS
# Keep redirected logs machine-readable while preserving terminal colors.
# ------------------------------------------------------------------------------
ifeq ($(shell test -t 2 && printf yes),yes)
C_RESET := $(shell printf '\033[0m')
C_BLUE  := $(shell printf '\033[34m')
C_GREEN := $(shell printf '\033[32m')
C_YELLOW:= $(shell printf '\033[33m')
C_RED   := $(shell printf '\033[31m')
else
C_RESET :=
C_BLUE  :=
C_GREEN :=
C_YELLOW:=
C_RED   :=
endif

define info
	@echo "$(C_BLUE)[TF]$(C_RESET) $(1)"
endef

define success
	@echo "$(C_GREEN)[✔]$(C_RESET) $(1)"
endef

define warn
	@echo "$(C_YELLOW)[!] $(1)$(C_RESET)"
endef

define error
	@echo "$(C_RED)[✖] $(1)$(C_RESET)"
endef

# ------------------------------------------------------------------------------
# INCLUDE IMPLEMENTATION MODULES
# Umbrella Makefile declares orchestration only.
# ------------------------------------------------------------------------------
include scripts/make/k3.mk
include scripts/make/k3-ops.mk
include scripts/make/k3/k3-inventory.mk
include scripts/make/infra.mk
include scripts/make/cert-manager.mk
include scripts/make/istio.mk
include scripts/make/runtime.mk
include scripts/make/doctor.mk
include scripts/make/core.mk
include scripts/make/kubconfig.mk
include scripts/make/dev.mk
include scripts/make/forgesec.mk
include scripts/make/identity-controller.mk
include scripts/make/images.mk
include scripts/make/value-plane.mk
include scripts/make/civ.mk
include scripts/make/supplychain.mk
include scripts/make/registry-governance.mk
# cleanup-tests is intentionally opt-in and never called automatically (not part of make doctor)
include scripts/make/cleanup.mk

# Optional image UX targets (airgap / supply chain)
.PHONY: images airgap debug-image debug-shell

images: images-fetch images-import images-verify

airgap: images
	@echo "🛡 Airgap supply chain complete"

# Debug image UX (operator-only; non-evaluated)
debug-image: debug-image-fetch debug-image-import debug-image-verify

# Canonical debug and forgesec UX (build & run)
.PHONY: images-build images-forgesec

images-build: build-debug build-forgesec
	@echo "✔ Canonical images built"

images-forgesec:
	kubectl run forgesec \
	  --rm -it \
	  --restart=Never \
	  --image=$(FORGESEC_IMAGE) \
	  -- scan

debug-shell:
	kubectl run tf-debug \
	  -n threadforge-ops \
	  --restart=Never \
	  --rm -it \
	  --image=$(DEBUG_IMAGE) \
	  --command -- sh

# ------------------------------------------------------------------------------
# REVIEW-GRADE UX ALIASES
# ------------------------------------------------------------------------------
.PHONY: up down verify observe core-status
.PHONY: obs-validate
.PHONY: obs-validate-core obs-chaos-validate
.PHONY: test-policy-removal istio-validate lab-deploy agents-lab-deploy verify-all reset-environment check-idempotency demo demo-all
.PHONY: check-no-ignore-critical

check-no-ignore-critical:
	@if rg -n "type: ignore" platform/runtime/spire platform/runtime/api api scripts/proof; then \
		echo "[FAIL] type: ignore is forbidden in critical paths"; \
		exit 1; \
	else \
		echo "[OK] no type: ignore in critical paths"; \
	fi

.PHONY: enforce-registry
enforce-registry:
	@echo "Registry enforcement is handled by native ValidatingAdmissionPolicy 'enforce-internal-registry' — do NOT apply Kyverno ClusterPolicy."

.PHONY: policy-sync-digest-mirrors
policy-sync-digest-mirrors:
	@bash scripts/policy/sync_digest_policy_mirrors.sh

.PHONY: containment-audit
containment-audit:
	@PYTHONPATH="$$(pwd)" .venv/bin/python tools/dev/containment_audit.py

agents-lab-deploy:
	@$(MAKE) -C platform/labs/agent-containment deploy

demo: agents-lab-deploy
	@bash -euo pipefail -c '\
		failures=0; \
		echo "=== CONTAINMENT DEMO START ==="; \
		echo ""; \
		echo "[1] Allowed path"; \
		if code="$$(bash platform/labs/agent-containment/scenarios/allowed_write.sh)" && [ "$$code" = "200" ]; then \
			echo "[OK] Allowed path -> 200 OK"; \
		else \
			echo "[FAIL] Allowed path did not return 200"; failures=$$((failures + 1)); \
		fi; \
		echo ""; \
		echo "[2] Lateral movement"; \
		if out="$$(bash platform/labs/agent-containment/scenarios/attack_lateral.sh)" && grep -q "403" <<<"$$out"; then \
			echo "[OK] Lateral movement blocked -> 403"; \
		else \
			echo "[FAIL] Lateral movement was not denied with 403"; failures=$$((failures + 1)); \
		fi; \
		echo ""; \
		echo "[3] Exfiltration"; \
		if out="$$(bash platform/labs/agent-containment/scenarios/attack_exfiltration.sh)" && grep -q "BLOCKED" <<<"$$out"; then \
			echo "[OK] Exfiltration blocked -> BLOCKED"; \
		else \
			echo "[FAIL] Exfiltration was not blocked"; failures=$$((failures + 1)); \
		fi; \
		echo ""; \
		echo "[4] Service scan"; \
		if out="$$(bash platform/labs/agent-containment/scenarios/attack_scan.sh)" && grep -q "403" <<<"$$out"; then \
			echo "[OK] Service scan blocked -> 403"; \
		else \
			echo "[FAIL] Service scan was not denied with 403"; failures=$$((failures + 1)); \
		fi; \
		if [ "$$failures" -ne 0 ]; then \
			echo "Result: $$failures containment assertion(s) failed."; exit 1; \
		fi; \
		echo "Result: All unauthorized actions were mechanically denied."; \
		echo ""; echo "=== DEMO COMPLETE ==="'

demo-all:
	@bash scripts/demo/run_supported_demos.sh

.PHONY: supply-chain-verify
.PHONY: chaos-spire-kill chaos-spire-csr-kill chaos-trust-break chaos-recover

chaos-spire-kill:
	@bash scripts/chaos/spire_kill.sh

chaos-spire-csr-kill:
	@bash scripts/chaos/spire_csr_kill.sh

chaos-trust-break:
	@bash scripts/chaos/trust_break.sh

chaos-recover:
	@bash scripts/chaos/recover.sh

.PHONY: proof proof-determinism k8s-lint k8s-admission-check cluster-ready builder-setup lock-validate validate-all validate-all-full-reset golden-boot validate-shell validate-proof-integrity validate-proof-runner verify-main break-system ci-audit test-core test-all host-trust-prime topology-governance-check
.PHONY: prereq-check ci-parity-bootstrap ci-parity-snapshot test-env-up test-env-down
prereq-check:
	@bash scripts/lib/check_prereqs.sh

ci-parity-bootstrap:
	@bash scripts/ci/bootstrap_prereqs.sh

ci-parity-snapshot:
	@SNAPSHOT_FILE="$(if $(SNAPSHOT_FILE),$(SNAPSHOT_FILE),_ci_parity/ci_environment_snapshot.txt)"; \
	bash scripts/ci/capture_ci_environment.sh "$$SNAPSHOT_FILE"

builder-setup:
	@bash scripts/build/setup_builder.sh

test-core:
	@PYTHON_BIN="$(if $(wildcard .venv/bin/python),.venv/bin/python,$$(command -v python3))"; \
	if [[ -z "$$PYTHON_BIN" ]]; then \
		echo "python3 is required for pytest"; \
		exit 2; \
	fi; \
	"$$PYTHON_BIN" -m pytest -m core

test-all:
	@PYTHON_BIN="$(if $(wildcard .venv/bin/python),.venv/bin/python,$$(command -v python3))"; \
	if [[ -z "$$PYTHON_BIN" ]]; then \
		echo "python3 is required for pytest"; \
		exit 2; \
	fi; \
	"$$PYTHON_BIN" -m pytest

test-env-up:
	@echo "[test-env] Starting PostgreSQL on :15432"
	@docker rm -f tf-test-postgres 2>/dev/null || true
	@docker run -d --name tf-test-postgres \
		-p 15432:5432 \
		-e POSTGRES_DB=threadforge_test \
		-e POSTGRES_USER=threadforge_operator \
		-e POSTGRES_PASSWORD=threadforge \
		postgres:15-alpine \
		>/dev/null
	@echo "[test-env] Starting ClickHouse on :9000"
	@docker rm -f tf-test-clickhouse 2>/dev/null || true
	@docker run -d --name tf-test-clickhouse \
		-p 9000:9000 \
		-p 8123:8123 \
		clickhouse/clickhouse-server:24-alpine \
		>/dev/null
	@echo "[test-env] Waiting for PostgreSQL to be ready"
	@for i in $$(seq 1 30); do \
		docker exec tf-test-postgres pg_isready -U threadforge_operator -d threadforge_test >/dev/null 2>&1 && break; \
		sleep 1; \
	done
	@echo "[test-env] Waiting for ClickHouse to be ready"
	@for i in $$(seq 1 30); do \
		docker exec tf-test-clickhouse clickhouse-client --query "SELECT 1" >/dev/null 2>&1 && break; \
		sleep 1; \
	done
	@echo "[test-env] Applying PostgreSQL schema migrations"
	@cd data && DATABASE_URL="postgresql://threadforge_operator:threadforge@localhost:15432/threadforge_test" \
		$(REPO_ROOT)/.venv/bin/alembic -c db/alembic.ini upgrade head >/dev/null
	@echo "[test-env] Applying ledger immutability trigger"
	@docker exec -i tf-test-postgres psql -U threadforge_operator -d threadforge_test \
		-c "CREATE OR REPLACE FUNCTION prevent_ledger_mutation() RETURNS TRIGGER LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''LEDGER_IMMUTABLE: operator_ledger_v2 is append-only. % operation blocked.'', TG_OP USING ERRCODE = ''23502''; END;';" \
		>/dev/null
	@docker exec -i tf-test-postgres psql -U threadforge_operator -d threadforge_test \
		-c "DROP TRIGGER IF EXISTS enforce_immutability_operator_ledger ON operator_ledger_v2; CREATE TRIGGER enforce_immutability_operator_ledger BEFORE UPDATE OR DELETE ON operator_ledger_v2 FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();" \
		>/dev/null
	@echo "[test-env] All services ready with schema"

test-env-down:
	@echo "[test-env] Stopping test services"
	@docker rm -f tf-test-postgres tf-test-clickhouse 2>/dev/null || true
	@echo "[test-env] Done"

# ------------------------------------------------------------------------------
# proof — non-healing assurance with explicitly bounded active checks.
# Depends on infra-bootstrap having been run; does NOT call infra-bootstrap.
# Safe to repeat: make proof && make proof must produce identical results.
# ------------------------------------------------------------------------------
.PHONY: proof proof-active prove-active prove-spire-outage proof-determinism registry-audit registry-prune trust-init
.PHONY: proof-break-unsigned proof-break-external proof-break-spire proof-break-tamper
k8s-lint:
	@PYTHON_BIN="$(REPO_ROOT)/.venv/bin/python"; \
	if [ ! -x "$$PYTHON_BIN" ]; then \
		PYTHON_BIN="$$(command -v python || command -v python3)"; \
	fi; \
	"$$PYTHON_BIN" -m pytest -q tests/test_resource_requirements.py

k8s-admission-check:
	@kubectl apply --dry-run=server -f platform/deploy/infra/monitoring/debug/curl-pod.yaml >/dev/null
	@tmp_manifest="$$(mktemp)"; \
	tmp_err="$$(mktemp)"; \
	printf '%s\n' \
		'apiVersion: v1' \
		'kind: Pod' \
		'metadata:' \
		'  name: require-resources-negative' \
		'  namespace: default' \
		'spec:' \
		'  restartPolicy: Never' \
		'  containers:' \
		'    - name: missing-resources' \
		'      image: registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:ac9c255664075e199f0527b3ba61b0d09a907bde8e699777469dd0c9c43ba004' \
		'      command: ["sh", "-c", "echo should be denied"]' >"$$tmp_manifest"; \
	if kubectl apply --dry-run=server -f "$$tmp_manifest" > /dev/null 2>"$$tmp_err"; then \
		cat "$$tmp_err"; \
		rm -f "$$tmp_manifest"; \
		rm -f "$$tmp_err"; \
		echo "[FAIL] require-resources admission check did not reject a resource-less pod"; \
		exit 2; \
	fi; \
	grep -Eqi 'require-resources|CPU and memory requests and limits|denied' "$$tmp_err"; \
	rm -f "$$tmp_manifest"; \
	rm -f "$$tmp_err"

cluster-ready:
	@test -n "$${KUBECONFIG:-}"
	@kubectl cluster-info >/dev/null
	@kubectl get nodes >/dev/null
	@kubectl wait --for=condition=Ready nodes --all --timeout=60s >/dev/null
	@if kubectl get pods -A | grep -E 'CrashLoopBackOff|Error' >/dev/null; then \
		echo "cluster not healthy"; \
		exit 2; \
	fi

proof:
	@if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then \
		CI_RUNNER_CERT_PHASE="proof" bash scripts/ci/runner_pretrust_gate.sh --phase proof; \
	fi
	@$(MAKE) trust-init
	@bash -euo pipefail -c '. scripts/lib/proof_prereqs.sh; \
		export COSIGN_YES=true; \
		export MAX_RUNTIME=${MAX_RUNTIME:-2700}; \
		require_cluster_reachable_or_missing_prereq "Kubernetes cluster not reachable — kubectl cluster-info failed"; \
		require_supported_k8s_istio_combo_or_fail; \
		require_nodes_present_or_missing_prereq "no nodes found in cluster"; \
		require_nodes_ready_or_missing_prereq "cluster nodes not Ready within 30s"; \
		require_namespace_or_missing_prereq istio-system "control plane not initialized — namespace istio-system absent"; \
		require_namespace_or_missing_prereq kyverno "control plane not initialized — namespace kyverno absent"; \
		require_spire_server_ready_or_missing_prereq "control plane not initialized — spire-server not ready"; \
		require_deployment_or_missing_prereq istio-system istiod "control plane not initialized — istiod deployment absent"; \
		require_registry_healthy_or_missing_prereq "registry unreachable"; \
		bash scripts/proof/verify_proof_env_contract.sh; \
		SPIFFE_TRUST_DOMAIN=$${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local} THREADFORGE_PROOF_ENTRYPOINT=1 STRICT_MODE=true VERIFY_EXECUTION_MODE=proof THREADFORGE_PROOF_INCLUDE_ACTIVE_VERIFY=true bash scripts/prove_system.sh'
	@jq -e '.final == "PASS"' artifacts/proof/status.json >/dev/null || exit 2
	@jq -e '.signed == true' artifacts/proof/status.json >/dev/null || exit 2
	@jq -e '.verified == true' artifacts/proof/status.json >/dev/null || exit 2

proof-active:
	@bash -euo pipefail -c '. scripts/lib/proof_prereqs.sh; \
		export COSIGN_YES=true; \
		export MAX_RUNTIME=${MAX_RUNTIME:-2700}; \
		require_cluster_reachable_or_missing_prereq "Kubernetes cluster not reachable — kubectl cluster-info failed"; \
		require_supported_k8s_istio_combo_or_fail; \
		require_nodes_present_or_missing_prereq "no nodes found in cluster"; \
		require_nodes_ready_or_missing_prereq "cluster nodes not Ready within 30s"; \
		require_namespace_or_missing_prereq istio-system "control plane not initialized — namespace istio-system absent"; \
		require_namespace_or_missing_prereq kyverno "control plane not initialized — namespace kyverno absent"; \
		require_spire_server_ready_or_missing_prereq "control plane not initialized — spire-server not ready"; \
		require_deployment_or_missing_prereq istio-system istiod "control plane not initialized — istiod deployment absent"; \
		require_registry_healthy_or_missing_prereq "registry unreachable"; \
		bash scripts/proof/verify_proof_env_contract.sh; \
		SPIFFE_TRUST_DOMAIN=$${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local} THREADFORGE_PROOF_ENTRYPOINT=1 STRICT_MODE=true VERIFY_EXECUTION_MODE=proof-active THREADFORGE_PROOF_INCLUDE_ACTIVE_VERIFY=true bash scripts/prove_system.sh'
	@jq -e '.final == "PASS"' artifacts/proof/status.json >/dev/null || exit 2
	@jq -e '.signed == true' artifacts/proof/status.json >/dev/null || exit 2
	@jq -e '.verified == true' artifacts/proof/status.json >/dev/null || exit 2

prove-active:
	@set -euo pipefail; \
	echo "[ACTIVE] Starting active validation"; \
	( \
		bash scripts/proof/force_spire_rotation.sh && \
		bash scripts/verify/verify_cert_rotation_continuity.sh && \
		bash scripts/proof/test_admission_denials.sh \
	) || { echo "[ACTIVE] FAIL"; exit 2; }; \
	echo "[ACTIVE] PASS"

prove-spire-outage:
	@bash scripts/verify/prove_spire_outage.sh

trust-init:
	@mkdir -p artifacts/proof
	@sha256sum "$$HOME/.threadforge-signing/cosign.pub" | awk '{print $$1}' > artifacts/proof/cosign_root.sha256
	@bash scripts/audit/sign_signing_key_registry.sh >/dev/null
	@echo "[PASS] COSIGN_ROOT_PINNED"

.PHONY: trust-authority trust-drift trust-expiration trust-reconcile trust-reconcile-loop trust-continuity-proof trust-rotation-stress

trust-authority:
	@bash scripts/trust/update_trust_authority_state.sh

trust-drift:
	@bash scripts/trust/trust_drift_detector.sh

trust-expiration:
	@bash scripts/trust/trust_expiration_monitor.sh

trust-reconcile:
	@TRUST_RECONCILER_MODE=once bash scripts/trust/trust_continuity_reconciler.sh

trust-reconcile-loop:
	@TRUST_RECONCILER_MODE=continuous bash scripts/trust/trust_continuity_reconciler.sh

trust-continuity-proof:
	@bash scripts/verify/verify_trust_continuity.sh

trust-rotation-stress:
	@bash scripts/verify/test_trust_continuity_rotation.sh

# proof-determinism — runs proof twice and compares canonical artifacts.
# Requires infra-bootstrap. Missing baseline artifacts are not a determinism
# failure; the harness produces fresh proof runs and only fails for true
# prereq errors (MISSING_PREREQ) or deterministic drift (NON_DETERMINISM).
#
# Timeout hardening:
# ForgeSec enforcement in verify has an inner contract of identity(180s) +
# surface(240s). Warm-cluster sequential proof execution can push orchestration
# overhead close to the 480s outer verify timeout. Keep default proof semantics
# unchanged, but give determinism's two sequential proof runs bounded headroom.
#
# This override is intentionally phase-scoped and can be tuned externally.
DETERMINISM_FORGESEC_ENFORCEMENT_TIMEOUT_SECONDS ?= 600
proof-determinism:
	@bash -euo pipefail -c '. scripts/lib/proof_prereqs.sh; \
		require_command_or_missing_prereq jq "jq not available for determinism snapshot"; \
		require_command_or_missing_prereq sha256sum "sha256sum not available for determinism snapshot"; \
		require_cluster_reachable_or_missing_prereq "cluster not reachable for determinism"; \
		bash scripts/proof/verify_proof_env_contract.sh'
	@echo "[determinism] run 1"
	@FORGESEC_ENFORCEMENT_TIMEOUT_SECONDS="$${FORGESEC_ENFORCEMENT_TIMEOUT_SECONDS:-$(DETERMINISM_FORGESEC_ENFORCEMENT_TIMEOUT_SECONDS)}" $(MAKE) proof
	@test -f artifacts/proof/status.json || (echo "[FAIL] MISSING_PREREQ: artifacts/proof/status.json missing after proof run 1"; exit 2)
	@test -f artifacts/audit_logging_validation.json || (echo "[FAIL] MISSING_PREREQ: artifacts/audit_logging_validation.json missing after proof run 1"; exit 2)
	@test -f artifacts/proof/signed_images.txt || (echo "[FAIL] MISSING_PREREQ: artifacts/proof/signed_images.txt missing after proof run 1"; exit 2)
	@test -f artifacts/verify_results.json || (echo "[FAIL] MISSING_PREREQ: artifacts/verify_results.json missing after proof run 1"; exit 2)
	@cp artifacts/audit_logging_validation.json artifacts/.audit_logging_validation_run1.json
	@cp artifacts/proof/signed_images.txt artifacts/.signed_images_run1.txt
	@cp artifacts/verify_results.json artifacts/.verify_results_run1.json
	@timeout "$${DETERMINISM_SETTLE_TIMEOUT_SECONDS:-120}s" bash scripts/verify/wait_for_determinism_settle.sh || \
		(echo "[FAIL] CLEANUP_TIMEOUT: transient proof resources did not settle after run 1"; exit 2)
	@timeout "$${CLUSTER_DRIFT_TIMEOUT_SECONDS:-60}s" bash scripts/verify/snapshot_cluster_state.sh --json > artifacts/.cluster_snapshot_run1.json || \
		(echo "[FAIL] CLUSTER_DRIFT_TIMEOUT: unable to snapshot cluster state after run 1"; exit 2)
	@rm -rf artifacts/proof_run1
	@cp -r artifacts/proof artifacts/proof_run1
	@bash -euo pipefail -c '. scripts/lib/proof_prereqs.sh; \
		require_cluster_reachable_or_missing_prereq "cluster not reachable for determinism"'
	@echo "[determinism] run 2"
	@FORGESEC_ENFORCEMENT_TIMEOUT_SECONDS="$${FORGESEC_ENFORCEMENT_TIMEOUT_SECONDS:-$(DETERMINISM_FORGESEC_ENFORCEMENT_TIMEOUT_SECONDS)}" $(MAKE) proof
	@test -f artifacts/proof/status.json || (echo "[FAIL] MISSING_PREREQ: artifacts/proof/status.json missing after proof run 2"; exit 2)
	@timeout "$${DETERMINISM_SETTLE_TIMEOUT_SECONDS:-120}s" bash scripts/verify/wait_for_determinism_settle.sh || \
		(echo "[FAIL] CLEANUP_TIMEOUT: transient proof resources did not settle after run 2"; exit 2)
	@timeout "$${CLUSTER_DRIFT_TIMEOUT_SECONDS:-60}s" bash scripts/verify/snapshot_cluster_state.sh --json > artifacts/.cluster_snapshot_run2.json || \
		(echo "[FAIL] CLUSTER_DRIFT_TIMEOUT: unable to snapshot cluster state after run 2"; exit 2)
	@python3 scripts/proof/proof_hardening.py compare-cluster \
		artifacts/.cluster_snapshot_run1.json \
		artifacts/.cluster_snapshot_run2.json \
		artifacts/proof/latest/determinism_cluster_drift.json
	@echo "[determinism] comparing audit and signature artifacts"
	@bash scripts/verify/compare_determinism_artifact.sh json artifacts/.audit_logging_validation_run1.json artifacts/audit_logging_validation.json audit_logging_validation.json
	@bash scripts/verify/compare_determinism_artifact.sh text artifacts/.signed_images_run1.txt artifacts/proof/signed_images.txt signed_images.txt
	@bash scripts/verify/compare_determinism_artifact.sh json artifacts/.verify_results_run1.json artifacts/verify_results.json verify_results.json
	@echo "[determinism] comparing canonical artifacts"
	@echo "[determinism] first-drift extraction (artifact-by-artifact)"
	@python3 scripts/proof/proof_hardening.py compare-artifacts artifacts/proof_run1 artifacts/proof || \
		(echo "[FAIL] NON_DETERMINISM: first drift identified above — stopping"; exit 2)
	@python3 scripts/proof/proof_hardening.py compare artifacts/proof_run1 artifacts/proof

lock-validate:
	@set -euo pipefail; \
	PYTHON_BIN="$(if $(wildcard .venv/bin/python),.venv/bin/python,$$(command -v python3))"; \
	if [[ -z "$$PYTHON_BIN" ]]; then \
		echo "python3 is required for pytest"; \
		exit 2; \
	fi; \
	echo "[LOCK] Running core tests"; \
	"$$PYTHON_BIN" -m pytest -m core; \
	echo "[LOCK] Running proof"; \
	$(MAKE) proof; \
	echo "[LOCK] Running proof determinism"; \
	$(MAKE) proof-determinism; \
	echo "[LOCK] Running active validation"; \
	$(MAKE) prove-active; \
	echo "[LOCK] PASS"

validate-all:
	@if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then \
		CI_RUNNER_CERT_PHASE="validate-all" bash scripts/ci/runner_pretrust_gate.sh --phase validate-all; \
	fi
	@bash scripts/verify/validate_all.sh

validate-all-full-reset:
	@THREADFORGE_HOST_TRUST_MUTATION=allowed bash scripts/verify/validate_all.sh

# The sole native destructive lifecycle: persistent Ubuntu host + registry,
# disposable kind cluster, full bootstrap, then authoritative validation.
golden-boot:
	@bash scripts/operator/golden_boot.sh

validate-all-isolated:
	@bash scripts/verify/run_validate_all_isolated.sh

validate-shell:
	@bash -n scripts/verify/validate_all.sh

validate-proof-integrity:
	@bash scripts/verify/validate_proof_integrity.sh

validate-proof-runner:
	@echo "[validate-proof-runner] bash -n check..."
	@bash -n scripts/prove_system.sh || (echo "[FAIL] prove_system.sh has syntax errors"; exit 1)
	@echo "[validate-proof-runner] bash -n: PASS"
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "[validate-proof-runner] shellcheck..."; \
	  shellcheck -S warning scripts/prove_system.sh || (echo "[FAIL] shellcheck found issues"; exit 1); \
	  echo "[validate-proof-runner] shellcheck: PASS"; \
	else \
	  echo "[validate-proof-runner] shellcheck: not installed, skipping"; \
	fi
	@echo "[validate-proof-runner] PASS"

verify-main:
	@VALIDATE_PROOF_INTEGRITY_MODE=light bash scripts/verify/validate_proof_integrity.sh
	@bash scripts/verify/verify_main_integrity.sh
	@$(MAKE) ci-audit

break-system:
	@bash scripts/demo/break_system.sh

proof-break-unsigned:
	@echo "[TEST] Injecting unsigned image (expected admission FAIL)"
	@kubectl delete pod bad --ignore-not-found >/dev/null 2>&1 || true
	@kubectl run bad --image=nginx:latest --restart=Never 2>&1 | tee /tmp/admission.log || true
	@grep -Eqi "policy violation|denied the request|threadforge-require-signed-images|signature policy enforcement" /tmp/admission.log >/dev/null \
		&& echo "[PASS] ADMISSION_ENFORCED_UNSIGNED" \
		|| (echo "[FAIL] ADMISSION_NOT_ENFORCED"; exit 2)
	@kubectl delete pod bad --ignore-not-found >/dev/null 2>&1 || true

proof-break-external:
	@echo "[TEST] Injecting external image (expected admission FAIL)"
	@kubectl delete pod bad2 --ignore-not-found >/dev/null 2>&1 || true
	@kubectl run bad2 --image=busybox --restart=Never 2>&1 | tee /tmp/admission_ext.log || true
	@grep -Eqi "policy violation|denied the request|threadforge-require-image-digests|internal registry" /tmp/admission_ext.log >/dev/null \
		&& echo "[PASS] ADMISSION_ENFORCED_EXTERNAL" \
		|| (echo "[FAIL] ADMISSION_NOT_ENFORCED"; exit 2)
	@kubectl delete pod bad2 --ignore-not-found >/dev/null 2>&1 || true

proof-break-spire:
	@echo "[TEST] Breaking SPIRE (expected identity FAIL)"
	@kubectl delete pod -n spire-system -l app=spire-server >/dev/null 2>&1 || true
	@rc=0; $(MAKE) proof > /tmp/spire.log 2>&1 || rc=$$?; \
	classified=0; \
	if [ "$$rc" -eq 0 ]; then \
		echo "[FAIL] SPIRE_BREAK_NOT_DETECTED"; \
		kubectl -n spire-system rollout status statefulset/spire-server --timeout=120s >/dev/null 2>&1 || true; \
		kubectl -n istio-system rollout status deploy/spire-csr --timeout=120s >/dev/null 2>&1 || true; \
		bash scripts/verify/wait_for_data_plane_ready.sh >/dev/null 2>&1 || true; \
		exit 2; \
	fi; \
	if grep -Eqi "IDENTITY_CHAIN_VIOLATION|SPIRE bundle has no currently valid roots|non-deterministic active SPIRE root detected|identity_root == spire" /tmp/spire.log >/dev/null; then \
		echo "[PASS] IDENTITY_FAILURE_DETECTED"; \
		classified=1; \
	else \
		echo "[FAIL] IDENTITY_FAILURE_NOT_CLASSIFIED"; \
	fi; \
	kubectl -n spire-system rollout status statefulset/spire-server --timeout=120s >/dev/null 2>&1 || true; \
	kubectl -n istio-system rollout status deploy/spire-csr --timeout=120s >/dev/null 2>&1 || true; \
	bash scripts/verify/wait_for_data_plane_ready.sh >/dev/null 2>&1 || true; \
	if [ "$$classified" -ne 1 ]; then \
		exit 2; \
	fi

proof-break-tamper:
	@echo "[TEST] Tampering status.json (expected FAIL)"
	@$(MAKE) infra-bootstrap >/dev/null
	@$(MAKE) proof >/dev/null
	@tmp_dir="$$(mktemp -d)"; \
	cp artifacts/proof/status.json "$$tmp_dir/status.json"; \
	cp artifacts/proof/status.json.sig "$$tmp_dir/status.json.sig"; \
	echo "[TEST] Mutating isolated signed artifact"; \
	printf ' \n' >> "$$tmp_dir/status.json"; \
	set +e; STATUS_FILE="$$tmp_dir/status.json" STATUS_SIG="$$tmp_dir/status.json.sig" bash scripts/verify/verify_status_signature.sh > /tmp/tamper.log 2>&1; rc=$$?; set -e; \
	rm -rf "$$tmp_dir"; \
	if [ "$$rc" -eq 0 ]; then \
		echo "[FAIL] TAMPER_NOT_DETECTED"; \
		exit 2; \
	fi; \
	grep -q "STATUS_SIGNATURE_VERIFIED" /tmp/tamper.log && \
		(echo "[FAIL] SIGNATURE_CHECK_BYPASSED"; exit 2) || \
		echo "[PASS] TAMPER_DETECTED_SIGNATURE_MISMATCH"

registry-audit:
	@bash scripts/verify/registry_audit.sh

registry-prune:
	@bash scripts/registry/prune_unused_images.sh

.PHONY: verify-only
verify-only:
	@echo "[FAIL] VERIFY_ONLY is disabled in fail-closed proof mode"; echo "[ERROR] Use 'make proof' for authoritative validation";

.PHONY: cosign-keygen sign-images verify-signatures
cosign-keygen:
	@bash scripts/security/generate_cosign_keys.sh

sign-images:
	@COLLECT_SCOPE=cluster bash scripts/supply_chain/sign_images.sh

verify-signatures:
	@echo "[ADVISORY] Signature verification is performed inside 'make proof'. Not callable as a standalone gate."

.PHONY: validate validate-identity validate-system check
validate:
	@echo "[ADVISORY] artifact validation (non-gating):"
	@bash scripts/advisory/validate_artifacts.sh || true

validate-identity:
	@echo "[ADVISORY] Identity graph/index validation (non-gating):"
	@.venv/bin/python scripts/identity/generate_trust_matrix.py || true
	@.venv/bin/python scripts/validate_identity_graph.py || true
	@.venv/bin/python scripts/generate_validation_index.py || true

validate-system: validate
	@$(MAKE) validate-identity

check: validate

verify:
	@echo "[TF] verify: running repo structure and validation checks"
	@bash scripts/verify/verify_repo_canonical_structure.sh
	@bash scripts/verify/verify_repo_structure.sh

.PHONY: transient-artifact-check transient-artifact-cleanup
transient-artifact-check:
	@bash scripts/verify/cleanup_transient_artifacts.sh --check

transient-artifact-cleanup:
	@bash scripts/verify/cleanup_transient_artifacts.sh

topology-governance-check:
	@$(MAKE) transient-artifact-check
	@bash scripts/verify/verify_repository_topology.sh

observe:
	@echo "[ADVISORY] image drift observation is reported inside 'make proof' (prove_system.sh)."
core-status:
	@kubectl get pods -n threadforge-ops || true
	@$(MAKE) ops-failures

obs-validate-core:
	@echo "[ADVISORY] Observability diagnostic is non-gating and does not validate API authorization or determine system correctness."
	@bash scripts/advisory/observability/obs_phase2_validate.sh $(OBS_VALIDATE_FLAGS) || true

obs-chaos-validate:
	@echo "[ADVISORY] Observability chaos validation is an advisory operation."
	@bash scripts/advisory/observability/obs_chaos_validate.sh || true

obs-validate:
	@$(MAKE) obs-validate-core
	@$(MAKE) obs-chaos-validate

test-policy-removal:
	@bash scripts/test_policy_removal.sh

istio-validate:
	@echo "[ADVISORY] Istio validation (non-gating):"
	@bash scripts/advisory/validate_istio.sh || true

lab-deploy: observability-gate security-gate
	@bash scripts/deploy_lab.sh

verify-all:
	@echo "[ADVISORY] deterministic advisory run (non-gating):"
	@bash scripts/advisory/verify_all_deterministic.sh || true

reset-environment:
	@bash scripts/reset_environment.sh

check-idempotency:
	@bash scripts/check_idempotency.sh

# ------------------------------------------------------------------------------
# HELP
# ------------------------------------------------------------------------------
.PHONY: help
help:
	@echo ""
	@echo "$(C_BLUE)THREADFORGE — Command Map (Make System)$(C_RESET)"
	@echo "========================================================"
	@echo ""
	@echo "Canonical lifecycle commands:"
	@echo ""
	@echo "  $(C_GREEN)make golden-boot$(C_RESET)       — Canonical kind reset + bootstrap + validation [destructive]"
	@echo "  $(C_GREEN)make bootstrap$(C_RESET)         — Converge infrastructure on the current native kind cluster"
	@echo "  $(C_GREEN)make rebuild$(C_RESET)           — Alias of canonical Golden Boot [destructive]"
	@echo "  $(C_GREEN)make nuke CONFIRM=YES$(C_RESET)  — Delete native kind cluster; preserve host registry"
	@echo "  $(C_GREEN)make doctor$(C_RESET)            — Diagnostics + health checks [read-only]"
	@echo ""
	@echo "Validation and proof:"
	@echo ""
	@echo "  $(C_GREEN)make proof$(C_RESET)             — Non-healing proof with bounded active assurance [cluster-modifying]"
	@echo "  $(C_GREEN)make proof-determinism$(C_RESET) — Two canonical proof runs and semantic comparison [cluster-modifying]"
	@echo "  $(C_GREEN)make prove-active$(C_RESET)      — Active enforcement test [cluster-modifying]"
	@echo "  $(C_GREEN)make validate-all$(C_RESET)      — Authoritative scheduler [cluster-modifying]"
	@echo ""
	@echo "Bootstrap and infrastructure:"
	@echo ""
	@echo "  Non-native operator utilities: make k3-install, k3-reset, k3-wipe, kubeconfig-sync"
	@echo "  make infra-bootstrap, bootstrap-verify, infra-install, infra-nuke"
	@echo "  make infra-mesh, infra-policy, infra-observability, infra-telemetry"
	@echo "  make spire-install, istio-install, kyverno-install, cert-manager-install"
	@echo "  make gateway-install, namespaces-install"
	@echo ""
	@echo "Runtime and policy:"
	@echo ""
	@echo "  Secondary/unqualified: make runtime-init, runtime-nuke, runtime-health, runtime-deploy-api"
	@echo "  runtime-deploy-api is not native V1 qualified and is not cold-start supported"
	@echo "  make observability-gate, observability-enforce, security-gate"
	@echo "  make verify, observe, inspect, inspect-repo, inspect-cluster"
	@echo ""
	@echo "Supply chain and release:"
	@echo ""
	@echo "  make images, airgap, sign-images, verify-signatures"
	@echo "  make supply-chain-verify, supply-chain-verify-runtime, policy-sync-digest-mirrors"
	@echo "  make registry-audit, registry-prune, runtime-authority-closure"
	@echo ""
	@echo "Identity, trust, and observability:"
	@echo ""
	@echo "  make identity-golden-check — Verify native SPIRE identity source ownership"
	@echo "  make trust-authority, trust-drift, trust-expiration, trust-reconcile, trust-continuity-proof"
	@echo "  make k8s-lint, k8s-admission-check, cluster-ready"
	@echo ""
	@echo "Developer commands:"
	@echo ""
	@echo "  make test-local       — Run the canonical local test mode (skips allowed, reasons shown)"
	@echo "  make test-cluster     — Run cluster mode (zero skips allowed; fails closed)"
	@echo "  make test-full        — Start local test services, run full mode, and tear services down"
	@echo "  make format           — Auto-format (black + ruff --fix)"
	@echo "  make lint             — Ruff lint checks"
	@echo "  make typecheck        — Mypy type checking (venv)"
	@echo "  make test-unit        — Run unit tests only (default pytest behavior)"
	@echo "  make test-integration — Run integration tests (opt-in; set RUN_INTEGRATION=1 and required env vars)"
	@echo ""
	@echo "Diagnostics and utilities:"
	@echo ""
	@echo "  make audit, audit-check"
	@echo "  make mermaids, diagrams, containment-audit"
	@echo "  make mesh-codegen, mesh-autogen"
	@echo "  make kubeconfig-sync, kubeconfig-print"
	@echo "  make check-no-ignore-critical, check-idempotency, reset-environment"
	@echo ""
	@echo "Release and cleanup:"
	@echo ""
	@echo "  make verify, validate, validate-system, validate-all, verify-main"
	@echo "  make clean, nuke, rebuild, pen-test-clean"
	@echo ""
	@echo "Compatibility aliases:"
	@echo ""
	@echo "  make up -> bootstrap"
	@echo "  make down -> k3-down"
	@echo "  make civ-identity-enrichment-test-authorized -> demo-authority-contrast"
	@echo "  make verify -> repo structure validation checks"
	@echo "  make observe -> advisory image drift observation"
	@echo ""
	@echo "Safety tags: [read-only], [cluster-modifying], [destructive], [local-only], [network-required], [credential-required]"
	@echo ""

# ------------------------------------------------------------------------------
# CANONICAL LIFECYCLE TARGETS
# These targets must work from a fresh clone with no prior state.
# ------------------------------------------------------------------------------
.PHONY: install
install:
	@echo "[TF] install: setting up Python virtual environment..."
	@if [ ! -d .venv ]; then \
		python3 -m venv .venv; \
		echo "[TF] Created .venv"; \
	else \
		echo "[TF] .venv already exists — upgrading"; \
	fi
	@.venv/bin/pip install --quiet --upgrade pip
	@.venv/bin/pip install --quiet -r requirements.txt
	@echo "✔ install complete — run 'make test' to verify"

.PHONY: test
test:
	@echo "[TF] test: running unit test suite (no infra required)"
	@if [ ! -x .venv/bin/python ]; then \
		echo "[ERROR] .venv not found — run 'make install' first"; \
		exit 1; \
	fi
	@PYTHONPATH="$(ROOT)" .venv/bin/python -m pytest -m "not integration"

.PHONY: clean
clean:
	@echo "[TF] clean: removing runtime-generated artifact directories"
	@rm -rf artifacts/proof artifacts/security artifacts/audit artifacts/aas artifacts/logs
	@rm -rf runtime/ logs/ .pytest_tmp/
	@find . -name '__pycache__' -not -path './.venv/*' -exec rm -rf {} + 2>/dev/null || true
	@echo "✔ clean complete"

# ------------------------------------------------------------------------------
# AUDIT
# ------------------------------------------------------------------------------
# Phase-11 replay verification (read-only; manual trigger)
.PHONY: replay-verify
replay-verify:
	@echo "Run: scripts/replay-verify.sh --manifest <manifest> --ledger <ledger> --seals <dir> [--append-log]"
.PHONY: audit
audit:
	./scripts/audit/run_full_audit.sh

.PHONY: audit-check

audit-check:
	./scripts/audit/audit_self_check.sh

.PHONY: forensics-snapshot
forensics-snapshot:
	./scripts/forensics/filesystem_snapshot.sh

.PHONY: pen-test
pen-test:
	@echo "🛡 Pen-test entrypoint delegates to canonical ForgeSec k8s suites"
	@$(MAKE) security-gate

.PHONY: external-validate
external-validate: pen-test

.PHONY: security-gate
security-gate:
	@$(MAKE) forgesec

.PHONY: pen-test-clean
pen-test-clean:
	-kubectl delete namespace forgesec --ignore-not-found=true
	@echo "ForgeSec cleanup completed (artifacts preserved)"

.PHONY: mermaids
mermaids:
	@PYTHON_BIN="$(if $(wildcard .venv/bin/python),.venv/bin/python,$$(command -v python3))"; \
	if [[ -z "$$PYTHON_BIN" ]]; then \
		echo "python3 is required for Mermaid generation"; \
		exit 2; \
	fi; \
	if [[ -f artifacts/audit/LATEST ]]; then \
		LATEST_DIR=$$(cat artifacts/audit/LATEST); \
		if [[ -d "$$LATEST_DIR" ]]; then \
			"$$PYTHON_BIN" scripts/generate_mermaids.py "$$LATEST_DIR"; \
		else \
			echo "Latest audit directory not found; regenerating canonical audit first..."; \
			$(MAKE) audit; \
			LATEST_DIR=$$(cat artifacts/audit/LATEST); \
			"$$PYTHON_BIN" scripts/generate_mermaids.py "$$LATEST_DIR"; \
		fi \
	else \
		echo "No canonical audit found; running make audit to generate artifacts/audit/LATEST..."; \
		$(MAKE) audit; \
		LATEST_DIR=$$(cat artifacts/audit/LATEST); \
		"$$PYTHON_BIN" scripts/generate_mermaids.py "$$LATEST_DIR"; \
	fi

.PHONY: diagrams

diagrams:
	bash scripts/view_diagrams.sh list


# ------------------------------------------------------------------------------
# PREFLIGHT
# - Ensures SSH connectivity to VM
# - Ensures VM time alignment
# - Applies ONLY when ThreadForge manages the VM lifecycle
# ------------------------------------------------------------------------------
.PHONY: preflight vm-preflight
preflight:
	$(call info,"Running local preflight checks…")
	@$(MAKE) lint
	@$(MAKE) typecheck
	@$(MAKE) k8s-lint
	@$(MAKE) test-unit
	$(call success,"Local preflight passed")

ci-audit:
	@.venv/bin/python scripts/verify/ci_audit.py

.PHONY: docs-verify
docs-verify:
	@bash scripts/verify/verify_mkdocs_strict.sh

vm-preflight:
	$(call info,"Running VM preflight checks…")
	@$(SSH) "echo ok" >/dev/null
	$(call success,"VM reachable")

	@VM_TS=$$($(SSH) "date +%s"); \
	OS_TS=$$(date +%s); \
	DIFF=$$((OS_TS-VM_TS)); \
	if [ $${DIFF#-} -gt 60 ]; then \
		$(call warn,"Clock drift detected ($$DIFF seconds)"); \
		$(call warn,"Run inside VM: sudo chronyc makestep"); \
	else \
		$(call success,"Clock aligned") ;\
	fi

# ==============================================================================
# SAFETY CHECK — block destructive ops unless explicitly allowed
# ==============================================================================
ifdef TF_PROTECT
    $(error ❌ Cluster protection enabled (TF_PROTECT=1) — destructive commands blocked)
endif

# ------------------------------------------------------------------------------
# GOLDEN UX — explicit lifecycle verbs
# ------------------------------------------------------------------------------
.PHONY: up down reset status
up: bootstrap
down: nuke
reset: cluster-reset bootstrap
status: core-status doctor

.PHONY: k3-down infra-mesh infra-policy infra-observability infra-telemetry
# Compatibility utility only; not part of the native kind lifecycle.
k3-down: k3-wipe
infra-mesh: istio-core-install
infra-policy: istio-policy-install
infra-observability: infra-observability-install
infra-telemetry: doctor-telemetry-gate

# ------------------------------------------------------------------------------
# BOOTSTRAP (NATIVE KIND PROFILE)
# ------------------------------------------------------------------------------
.PHONY: bootstrap
bootstrap: infra-bootstrap bootstrap-verify
	$(call success,"Native kind cluster converged")

# ------------------------------------------------------------------------------
# DEPENDENCY RULES
# ------------------------------------------------------------------------------
infra-identity: identity-golden-check
runtime-init: observability-gate security-gate

# ------------------------------------------------------------------------------
.PHONY: infra-install
infra-install: infra-bootstrap observability-gate security-gate

# ------------------------------------------------------------------------------
# NUKE (SAFE WIPE)
# ------------------------------------------------------------------------------
.PHONY: nuke
nuke:
	$(call warn,"Deleting the native ThreadForge kind cluster…")

	# Validate operator intent before cluster wipe
	@if [ "$(CONFIRM)" != "YES" ]; then \
	    echo "❌ Refusing to nuke cluster. Re-run with CONFIRM=YES"; \
	    exit 1; \
	fi

	$(MAKE) cluster-nuke
	$(call success,"Native kind cluster deleted; persistent host registry preserved")

# ------------------------------------------------------------------------------
# CLEAN REBUILD
# ------------------------------------------------------------------------------
.PHONY: rebuild ci-rebuild
rebuild:
	@if [ "$(THREADFORGE_EXECUTION_PROFILE)" = "ci" ]; then \
		$(MAKE) ci-rebuild; \
		exit $$?; \
	fi
	$(MAKE) golden-boot

ci-rebuild:
	@if [ "$(THREADFORGE_EXECUTION_PROFILE)" != "ci" ]; then \
		echo "[FAIL] ci-rebuild requires THREADFORGE_EXECUTION_PROFILE=ci"; \
		exit 2; \
	fi
	$(call info,"Performing CI-safe rebuild (disposable cluster reset + strict bootstrap)…")
	$(MAKE) cluster-reset
	$(MAKE) infra-bootstrap BOOTSTRAP_MODE=strict

# ------------------------------------------------------------------------------
# GOLDEN VERIFICATION
# ------------------------------------------------------------------------------
.PHONY: verify-golden golden-preflight identity-golden-check observability-gate observability-enforce security-enforce

verify-golden:
	@echo "[INFO] verify-golden delegates to the sole native lifecycle owner"
	@$(MAKE) golden-boot

golden-preflight:
	@echo "[ADVISORY] Golden Boot invariant checks (non-gating):"
	@bash platform/deploy/infra/validate/mtls_strict.sh || true
	@bash platform/deploy/infra/validate/authz_principals_only.sh || true
	@bash platform/deploy/infra/validate/no_explicit_service_protocol.sh || true

identity-golden-check:
	@test -f platform/identity/spire/entries.yaml
	@! grep -Fqi 'operator-ai' platform/identity/spire/entries.yaml
	@grep -Fq 'TRACKED_ENTRIES_FILE="$$REPO_ROOT/platform/identity/spire/entries.yaml"' scripts/proof/reconcile_spire_entries.sh
	@grep -Fq 'bash "$$REPO_ROOT/scripts/proof/reconcile_spire_entries.sh"' scripts/infra/bootstrap.sh
	@echo "[PASS] native SPIRE identity source is canonical and Operator-AI-free"

observability-gate:
	@echo "[ADVISORY] Running observability status check (non-gating)..."
	@bash scripts/advisory/observability/observability_check.sh || true
	@echo "[ADVISORY] Observability check complete — see output above."
	@echo ""
	@echo "OTLP Collector mTLS status:"
	@kubectl get deployment -n observability threadforge-collector -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]' && \
	  echo "  Collector Deployment Ready" || echo "  Collector Deployment not Ready"
	@kubectl get peerauthentication -n observability threadforge-collector -o jsonpath='{.spec.mtls.mode}' 2>/dev/null | grep -q 'STRICT' && \
	  echo "  PeerAuthentication mode=STRICT" || echo "  PeerAuthentication not STRICT"
	@kubectl get authorizationpolicy -n observability threadforge-collector 2>/dev/null | grep -q 'ALLOW' && \
	  echo "  AuthorizationPolicy enforced" || echo "  AuthorizationPolicy missing"

observability-enforce:
	@echo "[ADVISORY] Observability check (non-gating):"
	@bash scripts/advisory/observability/observability_check.sh || true
	@echo "[ADVISORY] ForgeSec security check (non-gating):"
	@$(MAKE) security-gate

# ------------------------------------------------------------------------------
# IDENTITY MANAGEMENT
# ------------------------------------------------------------------------------
# Native identity reconciliation is owned by scripts/proof/reconcile_spire_entries.sh.
# The retired generator targets are intentionally absent so the historical tree
# cannot be mistaken for a supported identity authority.

# ------------------------------------------------------------------------------
# ISTIO BACKUP
# ------------------------------------------------------------------------------
.PHONY: istio-backup
istio-backup:
	@echo "=== BACKING UP CURRENT ISTIO POLICIES ==="
	@rm -rf backups/istio
	@mkdir -p backups/istio
	@for ns in istio-system threadforge-system threadforge-apps observability; do \
		$(RUN_KUBECTL) get authorizationpolicies -n $$ns -o yaml > backups/istio/$$ns-authz.yaml; \
		$(RUN_KUBECTL) get peerauthentications -n $$ns -o yaml > backups/istio/$$ns-peer.yaml; \
		echo "Backed up $$ns"; \
	done
	@echo "✔ Backup complete"

# ------------------------------------------------------------------------------
# DOCTOR
# ------------------------------------------------------------------------------
# TESTING
# ------------------------------------------------------------------------------
.PHONY: test-identity test-fast test-local test-cluster test-full

THREADFORGE_PYTEST_ARGS := tests/ --ignore=tests/adversarial --no-header -rs

test-local:
	@PYTHON_BIN="$(if $(wildcard .venv/bin/python),.venv/bin/python,$$(command -v python3))"; \
	if [[ -z "$$PYTHON_BIN" ]]; then \
		echo "python3 is required for pytest"; \
		exit 2; \
	fi; \
	THREADFORGE_TEST_MODE=local "$$PYTHON_BIN" -m pytest $(THREADFORGE_PYTEST_ARGS)

test-cluster:
	@set -euo pipefail; \
	PYTHON_BIN="$(if $(wildcard .venv/bin/python),.venv/bin/python,$$(command -v python3))"; \
	if [[ -z "$$PYTHON_BIN" ]]; then \
		echo "python3 is required for pytest"; \
		exit 2; \
	fi; \
	$(MAKE) infra-bootstrap BOOTSTRAP_MODE=strict >/dev/null; \
	if [[ -z "$${THREADFORGE_INGRESS_URL:-}" ]]; then \
		NODE_IP="$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"; \
		if [[ -z "$$NODE_IP" ]]; then NODE_IP="127.0.0.1"; fi; \
		NODE_PORT="$$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null || true)"; \
		if [[ -z "$$NODE_PORT" ]]; then \
			NODE_PORT="$$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"; \
		fi; \
		if [[ -z "$$NODE_PORT" ]]; then \
			echo "THREADFORGE_INGRESS_URL could not be derived for cluster mode"; \
			exit 2; \
		fi; \
		export THREADFORGE_INGRESS_URL="http://$$NODE_IP:$$NODE_PORT"; \
		echo "[test-cluster] THREADFORGE_INGRESS_URL=$$THREADFORGE_INGRESS_URL"; \
	fi; \
	THREADFORGE_TEST_MODE=cluster "$$PYTHON_BIN" -m pytest $(THREADFORGE_PYTEST_ARGS)

test-identity:
	@$(MAKE) test-local

test-fast:
	@$(MAKE) test-local

test-full:
	@set -euo pipefail; \
	exit_code_file="$${TEST_FULL_EXIT_CODE_FILE:-/tmp/threadforge-test-full.exitcode}"; \
	mkdir -p "$$(dirname "$$exit_code_file")"; \
	trap 'status=$$?; printf "%s\n" "$$status" > "$$exit_code_file"; $(MAKE) test-env-down >/dev/null 2>&1 || true' EXIT; \
	$(MAKE) test-env-up; \
	$(MAKE) infra-bootstrap BOOTSTRAP_MODE=strict >/dev/null; \
	if [[ -z "$${THREADFORGE_INGRESS_URL:-}" ]]; then \
		NODE_IP="$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"; \
		if [[ -z "$$NODE_IP" ]]; then NODE_IP="127.0.0.1"; fi; \
		NODE_PORT="$$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null || true)"; \
		if [[ -z "$$NODE_PORT" ]]; then \
			NODE_PORT="$$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"; \
		fi; \
		if [[ -z "$$NODE_PORT" ]]; then \
			echo "THREADFORGE_INGRESS_URL could not be derived for full mode"; \
			exit 2; \
		fi; \
		export THREADFORGE_INGRESS_URL="http://$$NODE_IP:$$NODE_PORT"; \
		echo "[test-full] THREADFORGE_INGRESS_URL=$$THREADFORGE_INGRESS_URL"; \
	fi; \
	PYTHON_BIN="$(if $(wildcard .venv/bin/python),.venv/bin/python,$$(command -v python3))"; \
	if [[ -z "$$PYTHON_BIN" ]]; then \
		echo "python3 is required for pytest"; \
		exit 2; \
	fi; \
	THREADFORGE_TEST_MODE=full "$$PYTHON_BIN" -m pytest $(THREADFORGE_PYTEST_ARGS); \
	$(MAKE) validate-all; \
	$(MAKE) validate-proof-integrity; \
	bash scripts/verify/verify_mode_artifact_parity.sh capture test-full

.PHONY: mode-timings
mode-timings:
	@set -euo pipefail; \
	t_local="$$(/usr/bin/time -p $(MAKE) test-local >/tmp/tf-test-local.log 2>&1 || true; awk '/^real /{print $$2}' /tmp/tf-test-local.log | tail -1)"; \
	t_cluster="$$(/usr/bin/time -p $(MAKE) test-cluster >/tmp/tf-test-cluster.log 2>&1 || true; awk '/^real /{print $$2}' /tmp/tf-test-cluster.log | tail -1)"; \
	t_full="$$(/usr/bin/time -p $(MAKE) test-full >/tmp/tf-test-full.log 2>&1 || true; awk '/^real /{print $$2}' /tmp/tf-test-full.log | tail -1)"; \
	t_validate="$$(/usr/bin/time -p $(MAKE) validate-all >/tmp/tf-validate-all.log 2>&1 || true; awk '/^real /{print $$2}' /tmp/tf-validate-all.log | tail -1)"; \
	echo "MODE_TIMINGS:"; \
	echo "  local: $${t_local}s"; \
	echo "  cluster: $${t_cluster}s"; \
	echo "  full: $${t_full}s"; \
	echo "  validate-all: $${t_validate}s"

# ------------------------------------------------------------------------------
# MESH GENERATION
# ------------------------------------------------------------------------------
.PHONY: mesh-codegen mesh-autogen

mesh-codegen:
	@echo "🔧 Generating mesh policies…"
	python3 platform/deploy/controllers/sovereign-governor/codegen/compiler.py
	@echo "✔ Mesh policy generation complete"

mesh-autogen:
	watchmedo shell-command \
	  --patterns="*.yaml" \
	  --command="make mesh-codegen" \
	  platform/deploy/controllers/sovereign-governor/lattice

# ------------------------------------------------------------------------------
# INSPECTOR TARGETS
# ------------------------------------------------------------------------------
.PHONY: inspect inspect-repo inspect-cluster

inspect:
	@cd $(REPO_ROOT) && python3 -m inspector.inspect

inspect-repo:
	@cd $(REPO_ROOT) && python3 -m inspector.inspect

inspect-cluster:
	@cd $(REPO_ROOT) && python3 -m inspector.inspect

.PHONY: docs-load

docs-load:
	@python -m inspector.render.run
	@echo "📘 Renderer successfully loaded Inspector artifacts"

.PHONY: docs

docs: inspect
	@cd $(REPO_ROOT) && python3 -m inspector.render.docs_gen
	@echo "📄 Documentation generation complete"

.PHONY: docs-export
docs-export: docs
	@mkdir -p out/review
	@cp -r out/docs out/review/
	@cp -r out/inspect out/review/
	@cp CANONICAL_AUTHORITY.md out/review/
	@echo "📦 Reviewer packet exported to out/review/"

# ------------------------------------------------------------------------------
# SITE: lightweight static site generation for docs
# ------------------------------------------------------------------------------
.PHONY: site-build site-serve

site-build:
	@python3 scripts/generate_site.py
	@echo "✔ site/ directory generated (run 'make site-serve' to serve locally)"

# ------------------------------------------------------------------------------
# Astro-based public site build
# ------------------------------------------------------------------------------
site-astro-build:
	@echo "Building Astro site (site/) — ensure node and npm installed"
	@cd site && npm install --no-audit --no-fund >/dev/null 2>&1 || true
	@cd site && npm run build || true

site-demo-export:
	@bash scripts/export_demo.sh
	@echo "✔ demo export completed"

# ------------------------------------------------------------------------------
# CIV (Causal Inference & Validation) metric runner
# ------------------------------------------------------------------------------
.PHONY: civ-metric civ-metrics-all civ-metric-export

civ-metric:
	@if [ -z "$(METRIC)" ]; then \
		echo "ERROR: METRIC not set"; \
		echo "Usage: make civ-metric METRIC=policy_pressure"; \
		exit 2; \
	fi
	@./tools/verify/civ/run_civ_query.sh queries/civ_interfaces/$(METRIC).sql

civ-metric-export:
	@if [ -z "$(METRIC)" ]; then \
		echo "ERROR: METRIC not set"; exit 2; \
	fi
	@mkdir -p exports
	@./tools/verify/civ/run_civ_query.sh queries/civ_interfaces/$(METRIC).sql \
	  | sed '1,5d' > exports/$(METRIC).csv
	@echo "✔ Exported to exports/$(METRIC).csv (header rows removed for portability)"

civ-metrics-all:
	@for q in queries/civ_interfaces/*.sql; do \
		echo ""; \
		echo ">>> Running $$q"; \
		./tools/verify/civ/run_civ_query.sh $$q; \
	done

site-serve:
	@echo "Serving site on http://localhost:8000"
	@python3 -m http.server --directory site 8000

# ==============================================================================
# END UMBRELLA MAKEFILE
# ==============================================================================
