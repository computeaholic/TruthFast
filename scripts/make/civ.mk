.PHONY: civ-identity-attribution-test
civ-identity-attribution-test:
	@echo "▶ Running CIV Identity Attribution Test (read-only)"
	@tools/verify/civ/civ_identity_attribution_test_runner.sh

.PHONY: civ-sbom-governance-test
civ-sbom-governance-test:
	@echo "▶ Running CIV SBOM Governance Test (read-only, v1)"
	@tools/verify/civ/civ_sbom_governance_test_runner.sh

.PHONY: civ-network-governance-test
civ-network-governance-test:
	@echo "▶ Running CIV Network Governance Test (read-only, v1)"
	@tools/verify/civ/civ_network_governance_test_runner.sh

.PHONY: civ-io-governance-test
civ-io-governance-test:
	@echo "▶ Running CIV IO Governance Test (read-only, v1)"
	@tools/verify/civ/civ_io_governance_test_runner.sh

.PHONY: civ-identity-enrichment-test
civ-identity-enrichment-test:
	@echo "▶ Running CIV Identity Enrichment Test (read-only, v1)"
	@tools/verify/civ/civ_identity_enrichment_test_runner.sh

.PHONY: civ-authority-noncreation-test
civ-authority-noncreation-test:
	@echo "▶ Running CIV Authority Non-Creation (negative capability) Test"
	@tools/verify/civ/civ_authority_noncreation_test.sh

.PHONY: demo-authority-contrast civ-identity-enrichment-test-authorized
civ-identity-enrichment-test-authorized: demo-authority-contrast
demo-authority-contrast:
	@echo "▶ DEMO: Authority Contrast (opt-in)"
	@echo "Phase 1: Baseline (no authority)"
	@tools/verify/civ/demo_unload_identity_authority.sh
	@tools/dev/demo/demo_unload_identity_authority_full.sh
	@make civ-identity-enrichment-test
	@tools/dev/demo/move_last_identity_artifact.sh artifacts/civ/identity-enrichment-test/baseline
	@echo "Phase 2: Minimal Authority (existing demo)"
	@tools/verify/civ/demo_load_identity_authority.sh
	@make civ-identity-enrichment-test
	@tools/dev/demo/move_last_identity_artifact.sh artifacts/civ/identity-enrichment-test/minimal-authority
	@echo "Phase 3: Full Authority (demo full)"
	@tools/dev/demo/demo_unload_identity_authority_full.sh
	@tools/dev/demo/demo_load_identity_authority_full.sh
	@make civ-identity-enrichment-test
	@tools/dev/demo/move_last_identity_artifact.sh artifacts/civ/identity-enrichment-test/full-authority
	@echo "Demo completed. Artifacts under artifacts/civ/identity-enrichment-test/"

.PHONY: demo-security-boundary
demo-security-boundary:
	@echo "▶ DEMO: Security Boundary (ForgeSec)"
	@$(MAKE) forgesec
	@echo "Artifacts under artifacts/forgesec/"
.PHONY: demo-civ
demo-civ: value-plane-schema-apply value-plane-semantics value-plane-policy-economics value-plane-budgets value-plane-counterfactual
	@echo "==============================="
	@echo " THREADFORGE :: EXECUTIVE DEMO "
	@echo "==============================="
	@echo ""
	@echo "▶ [1/4] CPU Governance Test"
	@make civ-cpu-governance-test
	@echo ""
	@echo "▶ [2/4] Memory Governance Test"
	@make civ-memory-governance-test
	@echo ""
	@echo "▶ [3/4] Identity Attribution Test"
	@tools/verify/civ/civ_identity_attribution_test_runner.sh
	@echo ""
	@echo "▶ [4/4] SBOM Governance Test (opt-in)"
	@echo "(Run manually: make civ-sbom-governance-test)"
	@echo ""
	@echo "==============================="
	@echo " DEMO COMPLETE "
	@echo "==============================="
	@echo ""
	@echo "Artifacts:"
	@ls -1d artifacts/civ/*-test/* | grep -E 'OUTPUT.txt|METADATA.yaml|GIT_SHA|CLAIMS.md' || true
	@echo "Timestamp: $$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	@echo "Git SHA: $$(git rev-parse HEAD)"

.PHONY: civ-status
civ-status:
	@echo "▶ Running Civ status (read-only; authoritative)"
	@tools/verify/civ/civ_status.sh
