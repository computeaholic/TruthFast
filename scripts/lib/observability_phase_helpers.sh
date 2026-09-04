#!/usr/bin/env bash

observability_find_ns_by_service() {
	local svc="$1"
	run_real_kubectl get svc -A --no-headers 2>/dev/null | awk -v s="$svc" '$2 == s {print $1}' | head -1
}

observability_discover_svc_url() {
	local ns="$1"
	local svc="$2"
	local port=""
	port="$(run_real_kubectl get svc -n "$ns" "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
	if [ -n "$port" ]; then
		printf 'http://%s.%s.svc.cluster.local:%s\n' "$svc" "$ns" "$port"
	fi
}

observability_discover_endpoints() {
	local ns="$1"
	local svc="$2"
	run_real_kubectl get endpoints -n "$ns" "$svc" -o jsonpath='{range .subsets[*]}{range .addresses[*]}{.ip}{":"}{range $.subsets[*].ports[*]}{.port}{","}{end}{";"}{end}{end}' 2>/dev/null || true
}

observability_find_exec_pod() {
	local ns="$1"
	local injected_pod=""
	injected_pod="$({
		run_real_kubectl get pods -n "$ns" --field-selector=status.phase=Running \
			-o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{","}{end}{"\n"}{end}' 2>/dev/null \
			| awk -F'\t' 'index($2, "istio-proxy") > 0 {print $1; exit}'
	} || true)"
	if [ -n "$injected_pod" ]; then
		printf '%s\n' "$injected_pod"
		return 0
	fi

	run_real_kubectl get pods -n "$ns" --field-selector=status.phase=Running \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

observability_exec_curl() {
	local ns="$1"
	local pod="$2"
	local url="$3"
	local args="${4:---silent --show-error --max-time 10}"
	run_real_kubectl exec -n "$ns" "$pod" -c istio-proxy -- curl $args "$url" 2>/dev/null \
		|| run_real_kubectl exec -n "$ns" "$pod" -- curl $args "$url" 2>/dev/null \
		|| true
}

observability_component_target() {
	local ns="$1"
	local component="$2"
	local endpoint_target=""

	endpoint_target="$(run_real_kubectl -n "$ns" get endpoints "$component" -o jsonpath='{.subsets[*].addresses[*].targetRef.name}' 2>/dev/null | awk '{print $1}' || true)"
	if [ -n "$endpoint_target" ]; then
		printf '%s\n' "$endpoint_target"
		return 0
	fi

	if run_real_kubectl -n "$ns" get deploy "$component" >/dev/null 2>&1; then
		printf 'deploy/%s\n' "$component"
		return 0
	fi
	if run_real_kubectl -n "$ns" get statefulset "$component" >/dev/null 2>&1; then
		printf 'statefulset/%s\n' "$component"
		return 0
	fi

	run_real_kubectl -n "$ns" get pods -l "app=${component}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
