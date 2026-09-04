#!/usr/bin/env bash
set -euo pipefail

patch_workload() {
  local namespace="$1"
  local kind="$2"
  local name="$3"
  local priority_class="$4"
  local request_cpu="$5"
  local request_memory="$6"
  local limit_cpu="$7"
  local limit_memory="$8"
  local container_names patch_file

  if ! kubectl -n "$namespace" get "$kind" "$name" >/dev/null 2>&1; then
    return 0
  fi

  container_names="$(kubectl -n "$namespace" get "$kind" "$name" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
  if [ -z "$container_names" ]; then
    echo "[FAIL] tiering target has no containers: ${namespace}/${kind}/${name}" >&2
    exit 2
  fi

  patch_file="$(mktemp)"
  {
    cat <<EOF
spec:
  template:
    spec:
      priorityClassName: ${priority_class}
      containers:
EOF
    while IFS= read -r container_name; do
      [ -n "$container_name" ] || continue
      cat <<EOF
        - name: ${container_name}
          resources:
            requests:
              cpu: ${request_cpu}
              memory: ${request_memory}
            limits:
              cpu: ${limit_cpu}
              memory: ${limit_memory}
EOF
    done <<< "$container_names"
  } > "$patch_file"

  kubectl -n "$namespace" patch "$kind" "$name" --type=strategic --patch-file "$patch_file" >/dev/null
  rm -f "$patch_file"
  echo "[tiering] patched ${namespace}/${kind}/${name} -> ${priority_class}"
}

patch_workload istio-system deployment istiod threadforge-critical 500m 512Mi 1 1Gi
patch_workload istio-system deployment istio-ingressgateway threadforge-critical 250m 256Mi 1 1Gi
patch_workload istio-system deployment istio-egressgateway threadforge-critical 250m 256Mi 1 1Gi

patch_workload kyverno deployment kyverno-admission-controller threadforge-high 300m 256Mi 500m 2Gi
patch_workload kyverno deployment kyverno-background-controller threadforge-high 200m 256Mi 500m 512Mi
patch_workload kyverno deployment kyverno-cleanup-controller threadforge-high 150m 128Mi 500m 512Mi
patch_workload kyverno deployment kyverno-reports-controller threadforge-high 150m 128Mi 500m 512Mi
