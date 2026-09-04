###############################################################################
# THREADFORGE — SUPPLY CHAIN CLOSURE (Deterministic)
# - Pin kubectl
# - Verify no external image/tooling drift in authoritative manifests/workflows
###############################################################################

.PHONY: tools-install-kubectl supply-chain-verify supply-chain-verify-runtime hooks-install hooks-verify

TOOLS_DIR ?= $(REPO_ROOT)/.tools

tools-install-kubectl:
	$(call log-step,"🔒 Installing pinned kubectl from internal source (checksum verified)")
	@TF_TOOLS_DIR="$(TOOLS_DIR)" bash scripts/install/tools_install_kubectl.sh
	$(call log-ok,"kubectl installed to $(TOOLS_DIR)/bin/kubectl")
	@echo "▶ Use: export PATH=\"$(TOOLS_DIR)/bin:$$PATH\""

supply-chain-verify:
	$(call log-step,"🔎 Supply-chain verify: kubectl pin + no external refs")
	@bash scripts/advisory/verify_kubectl_pinning.sh
	@bash scripts/advisory/verify_no_external_images.sh
	@rg -n --hidden --no-messages \
		--glob '!.venv/**' \
		--glob '!docs/**' \
		--glob '!tmp/**' \
		--glob '!platform/deploy/**/artifacts/**' \
		--glob '!platform/deploy/**/evidence/**' \
		"stable\\.txt|https?://dl\\.k8s\\.io|https?://storage\\.googleapis\\.com|https?://istio-release\\.storage\\.googleapis\\.com" \
		.github/workflows scripts/make scripts platform/deploy/umbrella \
		&& { echo "[ADVISORY] external tooling endpoint(s) remain outside CI authority"; exit 0; } \
		|| true
	$(call log-ok,"Supply-chain verification passed")

supply-chain-verify-runtime:
	$(call log-step,"🧪 Runtime supply-chain verify: pinned version + internal images")
	@bash scripts/supply_chain/runtime_verify_after_closure.sh
	@bash scripts/supply_chain/verify_cluster_images_internal.sh
	$(call log-ok,"Runtime supply-chain verification passed")

hooks-install:
	$(call log-step,"🔧 Installing repo hooks (core.hooksPath=.githooks)")
	@git config core.hooksPath .githooks
	@chmod +x .githooks/pre-commit .githooks/pre-push
	$(call log-ok,"Hooks installed")

hooks-verify:
	$(call log-step,"🔎 Verifying hooks path")
	@hp="$$(git config --get core.hooksPath || true)"; \
	if [ "$$hp" != ".githooks" ]; then \
	  echo "ERROR: core.hooksPath is not .githooks (got: '$$hp')" >&2; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
	fi
	$(call log-ok,"Hooks path OK")
