###############################################################################
# THREADFORGE — REGISTRY GOVERNANCE MODULE (OBSERVE-ONLY)
# Additive governance scaffolding: no runtime or manifest mutation.
###############################################################################

.PHONY: verify-registry-ownership export-registry-provenance verify-floating-tags render-registry-governance-summary render-floating-tag-convergence-plan render-runtime-governance-health runtime-authority-closure

PYTHON_BIN ?= $(if $(wildcard $(REPO_ROOT)/.venv/bin/python),$(REPO_ROOT)/.venv/bin/python,$(shell command -v python3))

verify-registry-ownership:
	@$(PYTHON_BIN) scripts/verify/verify_registry_ownership.py

export-registry-provenance:
	@$(PYTHON_BIN) scripts/verify/export_registry_provenance.py

verify-floating-tags:
	@$(PYTHON_BIN) scripts/verify/verify_floating_tag_authority.py

render-registry-governance-summary:
	@$(PYTHON_BIN) scripts/verify/render_registry_governance_summary.py

render-floating-tag-convergence-plan:
	@$(PYTHON_BIN) scripts/verify/render_floating_tag_convergence_plan.py

render-runtime-governance-health:
	@$(PYTHON_BIN) scripts/verify/render_runtime_governance_health.py

runtime-authority-closure: verify-registry-ownership export-registry-provenance verify-floating-tags render-registry-governance-summary render-floating-tag-convergence-plan render-runtime-governance-health
