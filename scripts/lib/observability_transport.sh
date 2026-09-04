#!/usr/bin/env bash

# Bounded, observable transport for release-critical observability checks.
# The backend checks remain responsible for proving data-plane behavior.

OBSERVABILITY_PF_STARTUP_TIMEOUT_SECONDS="${OBSERVABILITY_PF_STARTUP_TIMEOUT_SECONDS:-15}"
OBSERVABILITY_PF_POLL_INTERVAL_SECONDS="${OBSERVABILITY_PF_POLL_INTERVAL_SECONDS:-0.2}"
OBSERVABILITY_PF_LOG_DIR="${OBSERVABILITY_PF_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/threadforge-observability-pf.XXXXXX")}"
mkdir -p "$OBSERVABILITY_PF_LOG_DIR"

OBSERVABILITY_PF_PIDS=()
OBSERVABILITY_LAST_FAILURE_CLASS=""
OBSERVABILITY_LAST_FAILURE_REASON=""

observability_pf_port_bound() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

observability_pf_cleanup() {
  local pid
  for pid in "${OBSERVABILITY_PF_PIDS[@]:-}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done
  OBSERVABILITY_PF_PIDS=()
}

observability_pf_fail() {
  local failure_class="$1"
  local reason="$2"
  local log_path="$3"
  OBSERVABILITY_LAST_FAILURE_CLASS="$failure_class"
  OBSERVABILITY_LAST_FAILURE_REASON="$reason"
  printf '[FAIL] OBSERVABILITY_%s: %s (stderr=%s)\n' \
    "$failure_class" "$reason" "$log_path" >&2
  if [[ -s "$log_path" ]]; then
    sed -n '1,20p' "$log_path" >&2
  fi
  return 1
}

observability_pf_open() {
  local service="$1"
  local namespace="$2"
  local local_port="$3"
  local remote_port="$4"
  local kubectl_bin="${KUBECTL_BIN:-kubectl}"
  local log_name="${service//[^A-Za-z0-9_.-]/_}-${local_port}.stderr"
  local log_path="$OBSERVABILITY_PF_LOG_DIR/$log_name"
  local endpoints
  local pid
  local rc
  local deadline

  : >"$log_path"

  if ! [[ "$local_port" =~ ^[0-9]+$ && "$remote_port" =~ ^[0-9]+$ ]]; then
    observability_pf_fail TRANSPORT_FAILURE \
      "invalid port mapping ${local_port}:${remote_port}" "$log_path"
    return 1
  fi
  if ! [[ "$OBSERVABILITY_PF_STARTUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    observability_pf_fail TRANSPORT_FAILURE \
      "invalid startup timeout: $OBSERVABILITY_PF_STARTUP_TIMEOUT_SECONDS" "$log_path"
    return 1
  fi
  if ! "$kubectl_bin" get service "$service" -n "$namespace" >/dev/null 2>"$log_path"; then
    observability_pf_fail BACKEND_UNAVAILABLE \
      "service $namespace/$service is absent" "$log_path"
    return 1
  fi
  if ! endpoints=$("$kubectl_bin" get endpoints "$service" -n "$namespace" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>>"$log_path"); then
    observability_pf_fail BACKEND_UNAVAILABLE \
      "could not inspect endpoints for $namespace/$service" "$log_path"
    return 1
  fi
  if [[ -z "${endpoints//[[:space:]]/}" ]]; then
    observability_pf_fail BACKEND_UNAVAILABLE \
      "service $namespace/$service has no ready endpoints" "$log_path"
    return 1
  fi
  if observability_pf_port_bound "$local_port"; then
    observability_pf_fail TRANSPORT_FAILURE \
      "local port $local_port is already bound" "$log_path"
    return 1
  fi

  "$kubectl_bin" port-forward "svc/$service" -n "$namespace" \
    "${local_port}:${remote_port}" --address=127.0.0.1 >>"$log_path" 2>&1 &
  pid=$!
  OBSERVABILITY_PF_PIDS+=("$pid")
  deadline=$((SECONDS + OBSERVABILITY_PF_STARTUP_TIMEOUT_SECONDS))

  while ((SECONDS < deadline)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      if wait "$pid" 2>/dev/null; then
        rc=0
      else
        rc=$?
      fi
      observability_pf_fail TRANSPORT_FAILURE \
        "port-forward for $namespace/$service exited before readiness (rc=$rc)" "$log_path"
      return 1
    fi
    if observability_pf_port_bound "$local_port"; then
      printf '[OBSERVABILITY_TRANSPORT_READY] %s/%s local=%s remote=%s pid=%s\n' \
        "$namespace" "$service" "$local_port" "$remote_port" "$pid"
      return 0
    fi
    sleep "$OBSERVABILITY_PF_POLL_INTERVAL_SECONDS"
  done

  observability_pf_fail TRANSPORT_FAILURE \
    "port-forward for $namespace/$service did not bind local port $local_port within ${OBSERVABILITY_PF_STARTUP_TIMEOUT_SECONDS}s" \
    "$log_path"
  return 1
}
