###############################################################################
# THREADFORGE — OPS MODULE
# Purpose:
#   - Convenience targets for logs/events during review
###############################################################################

.PHONY: ops-events ops-pods ops-failures logs-spire logs-istio

ops-events: kubeconfig-sync
	$(call log-step,"📜 Recent events")
	@$(RUN_KUBECTL) get events -A --sort-by=.lastTimestamp | tail -n 120 || true

ops-pods: kubeconfig-sync
	$(call log-step,"📦 Pods (all namespaces)")
	@$(RUN_KUBECTL) get pods -A -o wide

ops-failures: kubeconfig-sync
	$(call log-step,"💥 Non-running pods")
	@$(RUN_KUBECTL) get pods -A | egrep -v 'Running|Completed' || true

logs-spire: kubeconfig-sync
	$(call log-step,"🧬 SPIRE logs (server tail)")
	@$(RUN_KUBECTL) logs -n spire-system statefulset/spire-server --tail=120 2>/dev/null || true

logs-istio: kubeconfig-sync
	$(call log-step,"��️  Istio logs (istiod tail)")
	@$(RUN_KUBECTL) logs -n istio-system platform/deploy/istiod --tail=120 2>/dev/null || true
