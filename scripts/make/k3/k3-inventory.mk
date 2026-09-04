# ==============================================================================
# THREADFORGE — K3S NODE INVENTORY (V13 — Identity-First Edition)
# Dynamic-first with optional static fallback
# ==============================================================================

SHELL := /bin/bash

# Paths
STATIC_NODE_FILE ?= cluster/nodes.txt

# VM connection (inherited from root Makefile)
VM_IP      ?= 192.168.64.5
SSH        ?= ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null threadforge@$(VM_IP)

# ==============================================================================
# Helper: detect control-plane nodes
# ==============================================================================
define GET_CONTROL_PLANES
$(SSH) "sudo k3s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.node-role\.kubernetes\.io/control-plane}{\"\\n\"}{end}' \
	| awk '\$$2!=\"\" {print \$$1}'"
endef

define GET_WORKER_NODES
$(SSH) "sudo k3s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.labels.node-role\.kubernetes\.io/control-plane}{\"\\n\"}{end}' \
	| awk '\$$2==\"\" {print \$$1}'"
endef

# ==============================================================================
# Dynamic node discovery (identity-first, wrapper-consistent)
# ==============================================================================
define _DYNAMIC_NODES
$(RUN_KUBECTL) get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null
endef

# Node roles (important for AFRL-level cluster control discussions)
define _NODE_ROLES
$(RUN_KUBECTL) get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.labels."node-role\.kubernetes\.io/master"}{"\n"}{end}'
endef

# ==============================================================================
# Helper: Load static node inventory
# ==============================================================================

define _STATIC_NODES
@if [ -f "$(STATIC_NODE_FILE)" ]; then \
    awk '{print $$1}' $(STATIC_NODE_FILE); \
fi
endef

# ==============================================================================
# Public: NODE_LIST variable (dynamic-first, fallback to static)
# ==============================================================================

define GET_NODE_LIST
NODES="$$( $(call _DYNAMIC_NODES) )"; \
if [ -z "$$NODES" ]; then \
    echo "⚠️  Dynamic node discovery failed — using static inventory"; \
    NODES="$$( $(call _STATIC_NODES) )"; \
fi; \
if [ -z "$$NODES" ]; then \
    echo "❌ ERROR: No nodes detected (dynamic or static)"; \
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
fi; \
echo $$NODES
endef

# Export roles as helper target
.PHONY: k3-node-roles
k3-node-roles:
	@$(call _NODE_ROLES)

# ==============================================================================
# User Commands
# ==============================================================================

.PHONY: k3-role-inventory
k3-role-inventory:
	@echo "🔍 Role-based node inventory"
	@CP="$$( $(GET_CONTROL_PLANES) )"; \
	 WK="$$( $(GET_WORKER_NODES) )"; \
	echo ""; \
	echo "🛡  Control-plane nodes:"; \
	echo "$$CP"; \
	echo ""; \
	echo "⚙️  Worker nodes:"; \
	echo "$$WK"; \
	echo ""
