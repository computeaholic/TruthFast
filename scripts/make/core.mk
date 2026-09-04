###############################################################################
# THREADFORGE — CORE MAKE MODULE (V13.1 — REVIEW-GRADE KERNEL)
# - Deterministic orchestration surface for all included modules
# - No execution "modes"; environment is single canonical path.
#
# Enforcement invariant (P4 law):
#   - Identity always gates mutation.
#   - Observation without identity is valid and passing.
#   - Doctor output must reflect lawful state, not "missing feature" states.
#   - No projection or legacy switch may imply degraded authority.
###############################################################################

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# ------------------------------------------------------------------------------
# VERSION PINNING (REVIEWER-GRADE DETERMINISM)
# ------------------------------------------------------------------------------
ISTIO_VERSION := 1.29.0
CERT_MANAGER_VERSION := v1.19.2
SPIRE_VERSION := 1.9.x

# ------------------------------------------------------------------------------
# PATHS
# ------------------------------------------------------------------------------
REPO_ROOT ?= $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR ?= $(REPO_ROOT)/.state
KUBECONFIG_DIR ?= $(STATE_DIR)/kube
LOCAL_CONFIG ?= $(KUBECONFIG_DIR)/threadforge.yaml

# ------------------------------------------------------------------------------
# BINARIES (overridable)
# ------------------------------------------------------------------------------
KUBECTL ?= kubectl
HELM ?= helm

# ------------------------------------------------------------------------------
# KUBECTL/HELM WRAPPERS
# - Always use LOCAL_CONFIG when present (macOS/attached flow)
# - VM flow can also use LOCAL_CONFIG after kubeconfig-sync
# ------------------------------------------------------------------------------
ifeq ($(wildcard $(LOCAL_CONFIG)),)
  RUN_KUBECTL := $(KUBECTL)
  RUN_HELM   := $(HELM)
else
  RUN_KUBECTL := KUBECONFIG=$(LOCAL_CONFIG) $(KUBECTL)
  RUN_HELM   := KUBECONFIG=$(LOCAL_CONFIG) $(HELM)
endif

# ------------------------------------------------------------------------------
# LOGGING
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

define log-step
	@printf "$(C_BLUE)[TF]$(C_RESET) %s\n" "$(subst ",,$(1))"
endef
define log-ok
	@printf "$(C_GREEN)[OK]$(C_RESET) %s\n" "$(subst ",,$(1))"
endef
define log-warn
	@printf "$(C_YELLOW)[WARN]$(C_RESET) %s\n" "$(subst ",,$(1))"
endef
define log-error
	@printf "$(C_RED)[ERR]$(C_RESET) %s\n" "$(subst ",,$(1))"
endef

# ------------------------------------------------------------------------------
# GUARDS
# ------------------------------------------------------------------------------
.PHONY: core-verify-bins
core-verify-bins:
	$(call log-step,"🔎 Verifying required tooling…")
	@command -v $(KUBECTL) >/dev/null || { echo "[FAIL] kubectl missing"; exit 2; }
	@command -v $(HELM) >/dev/null || { echo "[FAIL] helm missing"; exit 2; }
	$(call log-ok,"kubectl + helm present")
# ----------------------------------------------------------------------------
# Test environment helpers
# ----------------------------------------------------------------------------
.PHONY: unset-test unset-test-shell
unset-test:
	@printf "[TF] Clearing test overrides for this make invocation (subshell only)...\n"
	@unset TEST_CASE >/dev/null 2>&1 || true
	@export PATH="$$(echo $$PATH | tr ':' '\n' | grep -v '^$(REPO_ROOT)/tests/mockbin$$' | paste -sd: -)"
	@printf "[TF] Done (subshell only). To apply to your shell, run: eval $$(make -s unset-test-shell)\n"

unset-test-shell:
	@echo "unset TEST_CASE; export PATH='$$(echo $$PATH | tr ':' '\n' | grep -v '^$(REPO_ROOT)/tests/mockbin$$' | paste -sd: -)'"
# ------------------------------------------------------------------------------
# IMAGE MANAGEMENT (Debug / ForgeSec)
# - Debug image is non-evaluated operator tooling
# - ForgeSec has two flavors: identity (authoritative identity checks)
#   and general (non-evaluated exploratory). Both are non-evaluated.
# ------------------------------------------------------------------------------
.PHONY: images-build-debug images-build-forgesec-identity images-build-forgesec-general

images-build-debug:
	@if [ "$(TF_RUNTIME)" != "linux-vm" ]; then \
		echo "❌ images-build-debug must run on the Ubuntu VM (TF_RUNTIME=linux-vm)"; \
		echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
	fi
	$(call log-step,"🔨 Building debug image")
	docker buildx build --builder threadforge-builder --platform linux/arm64 --output type=docker,dest=$(STATE_DIR)/threadforge-debug.tar -t $(CANON_DEBUG_IMAGE) platform/images/debug
	$(call log-ok,"$(CANON_DEBUG_IMAGE) built and saved")

images-build-forgesec-identity:
	@if [ "$(TF_RUNTIME)" != "linux-vm" ]; then \
		echo "❌ images-build-forgesec-identity must run on the Ubuntu VM (TF_RUNTIME=linux-vm)"; \
		echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
	fi
	$(call log-step,"🔨 Building forgesec identity image")
	docker buildx build --builder threadforge-builder --platform linux/arm64 --output type=docker,dest=$(STATE_DIR)/forgesec-identity.tar -t registry.threadforge.local:30500/forgesec-identity:rebuild-20260215 forgesec/identity
	$(call log-ok,"registry.threadforge.local:30500/forgesec-identity:rebuild-20260215 built and saved")

images-build-forgesec-general:
	@if [ "$(TF_RUNTIME)" != "linux-vm" ]; then \
		echo "❌ images-build-forgesec-general must run on the Ubuntu VM (TF_RUNTIME=linux-vm)"; \
		echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
	fi
	$(call log-step,"🔨 Building forgesec general image")
	docker buildx build --builder threadforge-builder --platform linux/arm64 --output type=docker,dest=$(STATE_DIR)/forgesec-general.tar -t registry.threadforge.local:30500/forgesec-general:rebuild-20260215 forgesec/general
	$(call log-ok,"registry.threadforge.local:30500/forgesec-general:rebuild-20260215 built and saved")

.PHONY: core-state-dirs
core-state-dirs:
	@mkdir -p $(STATE_DIR) $(KUBECONFIG_DIR)
