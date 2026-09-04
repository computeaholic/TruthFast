#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

VERSION="2.1.0"

REPORT_DIR="${FORGESEC_REPORT_DIR:-/home/secuser/reports}"
TS="$(date -u +%Y%m%d_%H%M%S)"
SUITE_CMD="${1:-suite}"
NAME="${2:-identity}"

mkdir -p "$REPORT_DIR"

LOG="${REPORT_DIR}/forgesec_${TS}_${NAME}.log"
JSON="${REPORT_DIR}/forgesec_${TS}_${NAME}.json"

FAIL=0
INFRA_FAIL=0
timeout_s="${FORGESEC_TIMEOUT_SEC:-3}"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
mark_fail() { FAIL=1; }
mark_infra() { INFRA_FAIL=1; }

jinit() {
  printf '{ "version":"%s","timestamp_utc":"%s","suite":"%s","results":[] }\n' \
    "$VERSION" "$(date -u +%FT%TZ)" "$NAME" > "$JSON"
}

set_outcome() {
  local outcome="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg outcome "$outcome" '.outcome = $outcome' "$JSON" > "$tmp" && mv "$tmp" "$JSON"
}

emit_json() {
  echo "FORGESEC_JSON_BEGIN"
  cat "$JSON"
  echo
  echo "FORGESEC_JSON_END"
}

jadd() {
  local tname="$1" status="$2" detail="$3"
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$tname" --arg s "$status" --arg d "$detail" \
    '.results += [{"test":$n,"status":$s,"detail":$d}]' "$JSON" > "$tmp" && mv "$tmp" "$JSON"
}

# Add a result entry classified as an infra failure with an explicit taxonomy key.
# Keeps backward-compatible fields and adds `classification` when provided.
jadd_class() {
  local tname="$1" status="$2" detail="$3" class="${4:-}"
  local tmp
  tmp="$(mktemp)"
  if [[ -n "$class" ]]; then
    jq --arg n "$tname" --arg s "$status" --arg d "$detail" --arg c "$class" \
      '.results += [{"test":$n,"status":$s,"detail":$d,"classification":$c}]' "$JSON" > "$tmp" && mv "$tmp" "$JSON"
  else
    jq --arg n "$tname" --arg s "$status" --arg d "$detail" \
      '.results += [{"test":$n,"status":$s,"detail":$d}]' "$JSON" > "$tmp" && mv "$tmp" "$JSON"
  fi
  INFRA_FAIL=1
}

require_bin() {
  local b="$1"
  if ! command -v "$b" >/dev/null 2>&1; then
    log "[INFRA_FAIL] missing binary: $b"
    jadd_class "infra.bin.${b}" "infra_fail" "binary not found" "binary_missing"
    mark_infra
  fi
}

record_violation() {
  local tname="$1" detail="$2"
  if [[ "$NAME" == "surface" && "${FORGESEC_STRICT_SURFACE:-0}" != "1" ]]; then
    log "[WARN] ${detail}"
    jadd "$tname" "warn" "$detail"
  else
    log "[FAIL] ${detail}"
    jadd "$tname" "fail" "$detail"
    mark_fail
  fi
}

dns_ok() {
  local host="$1"
  getent hosts "$host" >/dev/null 2>&1
}

tcp_open() {
  local host="$1" port="$2"
  nc -z -w "$timeout_s" "$host" "$port" >/dev/null 2>&1
}

test_dns() {
  local name="$1" host="$2"
  if dns_ok "$host"; then
    log "[PASS] dns resolves: ${name} ${host}"
    jadd "dns.${name}" "pass" "resolves"
  else
    log "[INFRA_FAIL] dns does not resolve: ${name} ${host}"
    jadd_class "dns.${name}" "infra_fail" "does not resolve" "dns_unavailable"
    mark_infra
  fi
}

test_tcp_expected_open() {
  local name="$1" host="$2" port="$3"
  if tcp_open "$host" "$port"; then
    log "[PASS] tcp open: ${name} ${host}:${port}"
    jadd "tcp.${name}" "pass" "open"
  else
    record_violation "tcp.${name}" "tcp not reachable (expected open): ${name} ${host}:${port}"
  fi
}

test_http_requires_auth_or_mtls() {
  local name="$1" host="$2" port="$3" path="${4:-/}"
  local code
  set +e
  code="$(timeout "${timeout_s}" curl -sS -o /dev/null -w '%{http_code}' "http://${host}:${port}${path}" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "[PASS] unauthenticated HTTP blocked (mTLS/TLS/network/auth gate): ${name} http://${host}:${port}${path}"
    jadd "http.unauth.${name}" "pass" "request blocked before HTTP success"
    return
  fi

  if [[ "$code" == "401" || "$code" == "403" || "$code" == "404" || "$code" == "405" ]]; then
    log "[PASS] unauthenticated HTTP denied or not exposed: ${name} status=${code}"
    jadd "http.unauth.${name}" "pass" "denied/not exposed (${code})"
    return
  fi

  record_violation "http.unauth.${name}" "unauthenticated HTTP unexpectedly succeeded: ${name} status=${code}"
}

test_registry_tls_verified() {
  local host="$1" port="$2"
  local code
  local -a curl_args=("https://${host}:${port}/v2/")

  if [[ -n "${FORGESEC_REGISTRY_CA_FILE:-}" ]]; then
    curl_args=(--cacert "$FORGESEC_REGISTRY_CA_FILE" "${curl_args[@]}")
  fi

  set +e
  code="$(timeout "${timeout_s}" curl -sS -o /dev/null -w '%{http_code}' "${curl_args[@]}" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    record_violation "registry.tls" "registry TLS verification failed: https://${host}:${port}/v2/"
    return
  fi

  if [[ "$code" == "200" || "$code" == "401" ]]; then
    log "[PASS] registry TLS verified and endpoint reachable: status=${code}"
    jadd "registry.tls" "pass" "tls verified, status=${code}"
  else
    record_violation "registry.tls" "registry returned unexpected status over TLS: status=${code}"
  fi
}

test_minio_requires_auth() {
  local host="$1" port="$2"
  local code
  set +e
  code="$(timeout "${timeout_s}" curl -sS -o /dev/null -w '%{http_code}' "http://${host}:${port}/" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "[PASS] minio unauthenticated access blocked before HTTP success"
    jadd "minio.auth" "pass" "blocked before HTTP success"
    return
  fi

  if [[ "$code" == "401" || "$code" == "403" ]]; then
    log "[PASS] minio rejects anonymous access: status=${code}"
    jadd "minio.auth" "pass" "anonymous denied (${code})"
  else
    record_violation "minio.auth" "minio allowed unexpected unauthenticated response: status=${code}"
  fi
}

test_pg_expect_fail() {
  local host="$1" port="$2"
  set +e
  timeout "${timeout_s}" psql "postgresql://invalid_user@${host}:${port}/postgres" -c '\\q' >/dev/null 2>&1
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    record_violation "postgres.auth" "postgres allowed invalid_user connect: ${host}:${port}"
  else
    log "[PASS] postgres rejected invalid user (expected): ${host}:${port}"
    jadd "postgres.auth" "pass" "rejected invalid user"
  fi
}

test_clickhouse_unauth_raw_tcp_rejected() {
  local host="$1" port="$2"
  local out
  set +e
  out="$(printf 'SELECT 1\n' | timeout "${timeout_s}" nc -w "$timeout_s" "$host" "$port" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$out" ]]; then
    log "[PASS] clickhouse unauthenticated raw TCP request was not accepted"
    jadd "clickhouse.auth" "pass" "raw unauthenticated request rejected"
    return
  fi

  if echo "$out" | grep -qiE 'exception|auth|authentication|unknown packet|code:'; then
    log "[PASS] clickhouse explicitly rejected unauthenticated raw TCP request"
    jadd "clickhouse.auth" "pass" "explicit server rejection"
    return
  fi

  if echo "$out" | grep -qiE 'ok|^1$|"data"'; then
    record_violation "clickhouse.auth" "clickhouse returned potential success to unauthenticated raw TCP probe"
    return
  fi

  log "[PASS] clickhouse did not provide successful unauthenticated raw TCP response"
  jadd "clickhouse.auth" "pass" "no successful unauthenticated response"
}

test_tempo_write_denied() {
  local host="$1" port="$2"
  local code
  set +e
  code="$(timeout "${timeout_s}" curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    --data '{}' "http://${host}:${port}/api/v2/spans" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "[PASS] tempo unauthenticated write path blocked before HTTP success"
    jadd "tempo.write.unauth" "pass" "blocked before HTTP success"
    return
  fi

  if [[ "$code" == "401" || "$code" == "403" || "$code" == "404" || "$code" == "405" ]]; then
    log "[PASS] tempo unauthenticated write API not exposed: status=${code}"
    jadd "tempo.write.unauth" "pass" "write denied/not exposed (${code})"
  else
    record_violation "tempo.write.unauth" "tempo write API responded unexpectedly to unauthenticated request: status=${code}"
  fi
}

test_strict_mtls_peer_authentication() {
  if [[ "${FORGESEC_REQUIRE_STRICT_MTLS:-0}" != "1" ]]; then
    jadd "mtls.strict" "skipped" "FORGESEC_REQUIRE_STRICT_MTLS=0"
    return
  fi

  local kube_host="${KUBERNETES_SERVICE_HOST:-}"
  local kube_port="${KUBERNETES_SERVICE_PORT:-}"
  local token_file="/var/run/secrets/kubernetes.io/serviceaccount/token"
  local ca_file="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  local token

  if [[ -z "$kube_host" || -z "$kube_port" || ! -r "$token_file" || ! -r "$ca_file" ]]; then
    log "[INFRA_FAIL] cannot evaluate STRICT mTLS invariant (missing in-cluster API context)"
    jadd_class "mtls.strict" "infra_fail" "cannot evaluate STRICT mTLS invariant (missing in-cluster API context)" "admission_unreachable"
    mark_infra
    return
  fi

  token="$(cat "$token_file")"
  local ns json rc count offenders
  local namespaces=(threadforge-system observability minio)

  for ns in "${namespaces[@]}"; do
    set +e
    json="$(timeout "${timeout_s}" curl -sS --fail \
      --cacert "$ca_file" \
      -H "Authorization: Bearer ${token}" \
      "https://${kube_host}:${kube_port}/apis/security.istio.io/v1beta1/namespaces/${ns}/peerauthentications" \
      2>/dev/null)"
    rc=$?
    set -e

    if [[ $rc -ne 0 || -z "$json" ]]; then
      record_violation "mtls.strict.${ns}" "failed to query PeerAuthentication in namespace ${ns}"
      continue
    fi

    count="$(echo "$json" | jq -r '.items | length' 2>/dev/null || echo "parse_error")"
    if [[ "$count" == "parse_error" ]]; then
      record_violation "mtls.strict.${ns}" "unable to parse PeerAuthentication response in namespace ${ns}"
      continue
    fi
    if [[ "$count" == "0" ]]; then
      record_violation "mtls.strict.${ns}" "no PeerAuthentication found in namespace ${ns}"
      continue
    fi

    offenders="$(echo "$json" | jq -r '.items[] | select((.spec.mtls.mode // "UNSET") != "STRICT") | .metadata.name + "=" + (.spec.mtls.mode // "UNSET")')"
    if [[ -n "$offenders" ]]; then
      record_violation "mtls.strict.${ns}" "non-STRICT PeerAuthentication found in ${ns}: ${offenders//$'\n'/, }"
    else
      log "[PASS] PeerAuthentication STRICT in namespace ${ns}"
      jadd "mtls.strict.${ns}" "pass" "all PeerAuthentication modes are STRICT"
    fi
  done
}

test_nmap_banner() {
  local name="$1" host="$2" port="$3"
  local out
  if [[ "${FORGESEC_NMAP_FAST:-1}" == "1" ]]; then
    out="$(nmap -sV -Pn --version-light --host-timeout "${timeout_s}s" -p "$port" "$host" 2>/dev/null || true)"
  else
    out="$(nmap -sV -Pn --host-timeout "${timeout_s}s" -p "$port" "$host" 2>/dev/null || true)"
  fi

  if [[ -z "$out" ]]; then
    log "[WARN] nmap returned no output: ${name} ${host}:${port}"
    jadd "nmap.${name}" "warn" "no output"
    return
  fi

  log "[INFO] nmap: ${name} ${host}:${port}"
  echo "$out" | sed 's/^/[INFO] /' | tee -a "$LOG" >/dev/null
  jadd "nmap.${name}" "pass" "probe complete"
}

usage() {
  cat <<EOF
ForgeSec Harness v${VERSION}
Usage:
  forgesec.sh suite <identity|surface|all>
  forgesec.sh shell

Suites:
  identity - blocking identity/auth/TLS boundary assertions
  surface  - observational network-surface checks (strict when FORGESEC_STRICT_SURFACE=1)
  all      - run identity then surface

Exit codes:
  0 = pass
  1 = structural violation detected
  2 = infrastructure problem prevented reliable verdict
EOF
}

run_identity() {
  local api_h="${FORGESEC_API_HOST}" api_p="${FORGESEC_API_PORT}"
  local pg_h="${FORGESEC_PG_HOST}" pg_p="${FORGESEC_PG_PORT}"
  local ch_h="${FORGESEC_CLICKHOUSE_HOST}" ch_p="${FORGESEC_CLICKHOUSE_PORT}"
  local m_h="${FORGESEC_MINIO_HOST}" m_p="${FORGESEC_MINIO_PORT}"
  local reg_h="${FORGESEC_REGISTRY_HOST}" reg_p="${FORGESEC_REGISTRY_PORT}"
  local g_h="${FORGESEC_GRAFANA_HOST}" g_p="${FORGESEC_GRAFANA_PORT}"
  local t_h="${FORGESEC_TEMPO_HOST}" t_p="${FORGESEC_TEMPO_PORT}"

  log "== identity =="

  test_dns "api" "$api_h"
  test_dns "postgres" "$pg_h"
  test_dns "clickhouse" "$ch_h"
  test_dns "minio" "$m_h"
  test_dns "registry" "$reg_h"
  test_dns "grafana" "$g_h"
  test_dns "tempo" "$t_h"

  test_strict_mtls_peer_authentication

  test_tcp_expected_open "api" "$api_h" "$api_p"
  test_tcp_expected_open "postgres" "$pg_h" "$pg_p"
  test_tcp_expected_open "clickhouse" "$ch_h" "$ch_p"
  test_tcp_expected_open "minio" "$m_h" "$m_p"
  test_tcp_expected_open "registry" "$reg_h" "$reg_p"
  test_tcp_expected_open "grafana" "$g_h" "$g_p"
  test_tcp_expected_open "tempo" "$t_h" "$t_p"

  test_pg_expect_fail "$pg_h" "$pg_p"
  test_clickhouse_unauth_raw_tcp_rejected "$ch_h" "$ch_p"
  test_minio_requires_auth "$m_h" "$m_p"

  if [[ "${FORGESEC_REQUIRE_REGISTRY_TLS:-1}" == "1" ]]; then
    test_registry_tls_verified "$reg_h" "$reg_p"
  else
    jadd "registry.tls" "skipped" "FORGESEC_REQUIRE_REGISTRY_TLS=0"
  fi

  test_http_requires_auth_or_mtls "api" "$api_h" "$api_p" "/"
  test_http_requires_auth_or_mtls "grafana" "$g_h" "$g_p" "/api/user"
  test_http_requires_auth_or_mtls "tempo" "$t_h" "$t_p" "/"
  test_tempo_write_denied "$t_h" "$t_p"
}

run_surface() {
  local api_h="${FORGESEC_API_HOST}" api_p="${FORGESEC_API_PORT}"
  local pg_h="${FORGESEC_PG_HOST}" pg_p="${FORGESEC_PG_PORT}"
  local ch_h="${FORGESEC_CLICKHOUSE_HOST}" ch_p="${FORGESEC_CLICKHOUSE_PORT}"
  local m_h="${FORGESEC_MINIO_HOST}" m_p="${FORGESEC_MINIO_PORT}"
  local g_h="${FORGESEC_GRAFANA_HOST}" g_p="${FORGESEC_GRAFANA_PORT}"
  local t_h="${FORGESEC_TEMPO_HOST}" t_p="${FORGESEC_TEMPO_PORT}"

  log "== surface =="

  test_dns "api" "$api_h"
  test_dns "postgres" "$pg_h"
  test_dns "clickhouse" "$ch_h"
  test_dns "minio" "$m_h"
  test_dns "grafana" "$g_h"
  test_dns "tempo" "$t_h"

  test_tcp_expected_open "api" "$api_h" "$api_p"
  test_tcp_expected_open "postgres" "$pg_h" "$pg_p"
  test_tcp_expected_open "clickhouse" "$ch_h" "$ch_p"
  test_tcp_expected_open "minio" "$m_h" "$m_p"
  test_tcp_expected_open "grafana" "$g_h" "$g_p"
  test_tcp_expected_open "tempo" "$t_h" "$t_p"

  test_nmap_banner "api" "$api_h" "$api_p"
  test_nmap_banner "postgres" "$pg_h" "$pg_p"
  test_nmap_banner "clickhouse" "$ch_h" "$ch_p"
  test_nmap_banner "minio" "$m_h" "$m_p"
  test_nmap_banner "grafana" "$g_h" "$g_p"
  test_nmap_banner "tempo" "$t_h" "$t_p"

  if [[ "${FORGESEC_EXPECT_NO_HTTP:-1}" == "1" ]]; then
    test_http_requires_auth_or_mtls "api" "$api_h" "$api_p" "/"
    test_http_requires_auth_or_mtls "grafana" "$g_h" "$g_p" "/api/user"
    test_http_requires_auth_or_mtls "tempo" "$t_h" "$t_p" "/"
  else
    jadd "http.expectation" "skipped" "FORGESEC_EXPECT_NO_HTTP=0"
  fi
}

main() {
  mkdir -p "$REPORT_DIR"
  : > "$LOG"
  jinit

  shutdown_proxy() {
    curl -sf -X POST http://127.0.0.1:15020/quitquitquit >/dev/null 2>&1 || true
  }
  trap shutdown_proxy EXIT

  require_bin curl
  require_bin jq
  require_bin nc
  require_bin getent
  require_bin nmap
  require_bin psql

  if [[ "$SUITE_CMD" == "shell" ]]; then
    exec /bin/bash
  fi

  if [[ "$SUITE_CMD" != "suite" ]]; then
    usage
    exit 2
  fi

  log "ForgeSec Harness v${VERSION}"
  log "Suite: ${NAME}"
  log "Report: ${LOG}"
  log "JSON:   ${JSON}"
  log "----"

  case "$NAME" in
    identity) run_identity ;;
    surface)  run_surface ;;
    all)      run_identity; run_surface ;;
    *) usage; exit 2 ;;
  esac

  log "----"
  if [[ "$INFRA_FAIL" -eq 1 ]]; then
    log "[INFRA_FAIL] one or more infra prerequisites failed; verdict not reliable"
    jadd_class "summary" "infra_fail" "prerequisites failed" "dependency_unavailable"
    set_outcome "infra_fail"
    emit_json
    exit 2
  fi

  # Emit provenance metadata (best-effort). This augments the report JSON with
  # a `provenance` object containing runtime-identifying fields when available.
  emit_provenance() {
    local pod_name ns token ca_file kube_host kube_port out tmp
    pod_name="${HOSTNAME:-}"
    ns=""
    if [[ -r "/var/run/secrets/kubernetes.io/serviceaccount/namespace" ]]; then
      ns="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
    fi
    token_file="/var/run/secrets/kubernetes.io/serviceaccount/token"
    ca_file="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    kube_host="${KUBERNETES_SERVICE_HOST:-}"
    kube_port="${KUBERNETES_SERVICE_PORT:-}"

    tmp="$(mktemp)"

    # Build a small provenance object we will merge into the JSON. This is
    # best-effort: if we can't reach the API or parse data, we still emit the
    # partial set of fields we have.
    jq -n --arg pod "${pod_name}" --arg ns "${ns}" '{provenance: {pod_name:$pod, namespace:$ns}}' > "$tmp"

    if [[ -n "$kube_host" && -r "$token_file" && -r "$ca_file" && -n "$pod_name" && -n "$ns" ]]; then
      set +e
      token="$(cat "$token_file" 2>/dev/null)"
      out="$(timeout 5s curl -sS --cacert "$ca_file" -H "Authorization: Bearer ${token}" \
        "https://${kube_host}:${kube_port}/api/v1/namespaces/${ns}/pods/${pod_name}" 2>/dev/null || true)"
      rc=$?
      set -e
      if [[ $rc -eq 0 && -n "$out" ]]; then
        # extract common provenance fields if present
        pod_uid="$(echo "$out" | jq -r '.metadata.uid // empty' 2>/dev/null || true)"
        node_name="$(echo "$out" | jq -r '.spec.nodeName // empty' 2>/dev/null || true)"
        sa_name="$(echo "$out" | jq -r '.spec.serviceAccountName // empty' 2>/dev/null || true)"
        images="$(echo "$out" | jq -c '[.spec.containers[]?.image] // []' 2>/dev/null || true)"
        image_ids="$(echo "$out" | jq -c '[.status.containerStatuses[]?.imageID] // []' 2>/dev/null || true)"
        jq --arg pu "$pod_uid" --arg nn "$node_name" --arg sa "$sa_name" --argjson imgs "$images" --argjson ids "$image_ids" \
          '.provenance += {pod_uid:$pu, node_name:$nn, service_account:$sa, container_images:$imgs, image_ids:$ids}' "$tmp" > "$tmp".new && mv "$tmp".new "$tmp"
      fi
    fi

    # merge provenance into report JSON
    jq -s '.[0] * .[1]' "$JSON" "$tmp" > "$tmp".merged && mv "$tmp".merged "$JSON"
    rm -f "$tmp"
  }

  emit_provenance

  if [[ "$FAIL" -eq 1 ]]; then
    log "[FAIL] structural violation detected"
    jadd "summary" "fail" "one or more assertions failed"
    set_outcome "fail"
    emit_json
    exit 1
  fi

  log "[PASS] all assertions passed"
  jadd "summary" "pass" "all assertions passed"
  set_outcome "pass"
  emit_json
  exit 0
}

main "$@"
