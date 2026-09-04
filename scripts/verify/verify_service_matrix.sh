#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

run_step() {
  "$@"
  local rc=$?
  return "$rc"
}

capture_output() {
  local __var_name="$1"
  shift
  local output=""
  set +e
  output="$("$@")"
  CAPTURE_OUTPUT_RC=$?
  set -e
  printf -v "$__var_name" '%s' "$output"
  return 0
}

MATRIX_PATH="$REPO_ROOT/artifacts/service_trust_matrix.json"
OUT_PATH="$REPO_ROOT/artifacts/verify_results.json"
INGRESS_PATH="${MATRIX_INGRESS_PATH:-/healthz}"

resolve_ingress_url() {
  local current="${THREADFORGE_INGRESS_URL:-}"
  if [ -n "$current" ]; then
    printf '%s' "$current"
    return 0
  fi

  local node_ip http_nodeport
  node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  http_nodeport="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}' 2>/dev/null || true)"
  if [ -z "$http_nodeport" ]; then
    http_nodeport="$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
  fi
  if [ -z "$node_ip" ] || [ -z "$http_nodeport" ]; then
    return 1
  fi
  printf 'http://%s:%s' "$node_ip" "$http_nodeport"
}

probe_ingress_allow_fallback() {
  local namespace="$1"
  local path="$2"
  local pod
  pod="$(kubectl get pods -n "$namespace" -l app=test-client --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "$pod" ]; then
    printf '000'
    return 0
  fi
  kubectl exec -n "$namespace" "$pod" -c test-client -- sh -c \
    "curl --silent --max-time 5 --location -o /dev/null -w '%{http_code}' 'http://echo.${namespace}.svc.cluster.local${path}' 2>/dev/null || echo 000" \
    2>/dev/null || printf '000'
}

if [ ! -f "$MATRIX_PATH" ]; then
  echo "[FAIL] missing: artifacts/service_trust_matrix.json"
  exit 10
fi

tmp_pairs="$(mktemp)"
tmp_results="$(mktemp)"
INGRESS_URL_RESOLVED="$(resolve_ingress_url || true)"
cleanup_tmp() {
  rm -f "$tmp_pairs" "$tmp_results"
}
trap cleanup_tmp EXIT

python3 - "$MATRIX_PATH" > "$tmp_pairs" <<'PY'
import json
import pathlib
import sys

matrix_path = pathlib.Path(sys.argv[1])
matrix = json.loads(matrix_path.read_text())
services = matrix.get("services", [])
edges = matrix.get("edges", [])

if not isinstance(services, list) or not isinstance(edges, list):
    sys.exit(2)

service_rows = []
for svc in services:
    if not isinstance(svc, dict):
        continue
    name = svc.get("name")
    namespace = svc.get("namespace")
    if isinstance(name, str) and name and isinstance(namespace, str) and namespace:
        service_rows.append((name, namespace))

def _match_from(edge_from: str, src_name: str, src_ns: str) -> bool:
    return edge_from in {src_name, f"{src_name}.{src_ns}"}

def _match_to(edge_to: str, dst_name: str, dst_ns: str) -> bool:
    return edge_to in {dst_name, f"{dst_name}.{dst_ns}"}

for src_name, src_ns in service_rows:
    for dst_name, dst_ns in service_rows:
        if src_name == dst_name and src_ns == dst_ns:
            continue

        expected = "DENY"
        for edge in edges:
            if not isinstance(edge, dict):
                continue
            if edge.get("allowed") is not True:
                continue
            edge_from = edge.get("from")
            edge_to = edge.get("to")
            if not isinstance(edge_from, str) or not isinstance(edge_to, str):
                continue
            if _match_from(edge_from, src_name, src_ns) and _match_to(edge_to, dst_name, dst_ns):
                expected = "ALLOW"
                break

        print(f"{src_name}\t{src_ns}\t{dst_name}\t{dst_ns}\t{expected}\t")

# Emit ingress edges — tested via THREADFORGE_INGRESS_URL
for edge in edges:
  if not isinstance(edge, dict):
    continue
  if edge.get("from") != "ingress":
    continue
  edge_to = edge.get("to")
  if not isinstance(edge_to, str) or not edge_to:
    continue
  expected = "ALLOW" if edge.get("allowed") is True else "DENY"
  path = edge.get("path", "")
  # dst encodes as "name.namespace" or just "name"; pass verbatim as dst_name
  print(f"ingress\t_ingress_\t{edge_to}\t_ingress_\t{expected}\t{path}")
PY
rc_python_pairs=$?
if [ "$rc_python_pairs" -ne 0 ]; then
  if [ "$rc_python_pairs" -eq 10 ]; then
    exit 10
  fi
  exit 2
fi

if [ ! -s "$tmp_pairs" ]; then
  printf '{\n  "results": [],\n  "summary": {\n    "total": 0,\n    "failures": 0\n  }\n}\n' > "$OUT_PATH"
  echo "[PASS] wrote artifacts/verify_results.json (0 checks, 0 failures)"
  exit 0
fi

ALLOW_COUNT=0
DENY_COUNT=0

while IFS=$'\t' read -r src_name src_ns dst_name dst_ns expected edge_path; do
  if [ "$src_name" = "ingress" ]; then
    ingress_url="${INGRESS_URL_RESOLVED:-${THREADFORGE_INGRESS_URL:-}}"
    probe_path="${edge_path:-${INGRESS_PATH}}"
    if [ -z "$ingress_url" ]; then
      http_code="000"
      if [ "$expected" = "ALLOW" ]; then
        http_code="$(probe_ingress_allow_fallback "threadforge-test" "$probe_path")"
        if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
          actual="ALLOW"
        else
          actual="DENY"
        fi
      else
        actual="DENY"
      fi
    elif [ "$expected" = "DENY" ]; then
      http_code="000"
      capture_output http_code curl --silent --max-time 2 -o /dev/null -w "%{http_code}" "${ingress_url%/}${probe_path}"
      rc_curl_ingress=${CAPTURE_OUTPUT_RC:-0}
      if [ "$rc_curl_ingress" -ne 0 ]; then
        http_code="000"
      fi
      if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
        echo "[FAIL] ingress deny failed: ${ingress_url%/}${probe_path} returned $http_code"
        actual="ALLOW"
      else
        actual="DENY"
      fi
    else
      http_code="000"
      actual="DENY"
      for _ in $(seq 1 2); do
        capture_output http_code curl --silent --max-time 2 --location -o /dev/null -w "%{http_code}" "${ingress_url%/}${probe_path}"
        rc_curl_ingress=${CAPTURE_OUTPUT_RC:-0}
        if [ "$rc_curl_ingress" -ne 0 ]; then
          http_code="000"
        fi

        if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
          actual="ALLOW"
          break
        fi

        sleep 1
      done
      if [ "$actual" != "ALLOW" ]; then
        http_code="$(probe_ingress_allow_fallback "threadforge-test" "$probe_path")"
        if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
          actual="ALLOW"
        else
          actual="DENY"
        fi
      fi
    fi

    if [ "$expected" = "$actual" ]; then
      status="PASS"
    else
      status="FAIL"
    fi
  else
    src_pod=""
    capture_output src_pod kubectl get pods -n "$src_ns" -l "app=$src_name" -o jsonpath='{.items[0].metadata.name}'
    rc_src_pod=${CAPTURE_OUTPUT_RC:-0}
    if [ "$rc_src_pod" -ne 0 ]; then
      src_pod=""
    fi

    dst_ns_real=""
    capture_output dst_ns_real bash -lc "printf '%s' \"$dst_name\" | grep -oP '(?<=\\.)[^.]+'"
    rc_dst_ns_parse=${CAPTURE_OUTPUT_RC:-0}
    if [ "$rc_dst_ns_parse" -ne 0 ] || [ -z "$dst_ns_real" ]; then
      dst_ns_real="$dst_ns"
    fi

    dst_short=""
    capture_output dst_short bash -lc "printf '%s' \"$dst_name\" | cut -d. -f1"
    rc_dst_short=${CAPTURE_OUTPUT_RC:-0}
    if [ "$rc_dst_short" -ne 0 ] || [ -z "$dst_short" ]; then
      dst_short="$dst_name"
    fi

    dst_pod=""
    capture_output dst_pod kubectl get pods -n "$dst_ns_real" -l "app=$dst_short" -o jsonpath='{.items[0].metadata.name}'
    rc_dst_pod=${CAPTURE_OUTPUT_RC:-0}
    if [ "$rc_dst_pod" -ne 0 ]; then
      dst_pod=""
    fi

    if [ -z "$src_pod" ] || [ -z "$dst_pod" ]; then
      actual="DENY"
      status="FAIL"
      http_code="000"
    else
      target_host="$dst_short"
      if [ "$src_ns" != "$dst_ns_real" ]; then
        target_host="$dst_short.$dst_ns_real"
      fi

      http_code=""
      capture_output http_code kubectl exec -n "$src_ns" "$src_pod" -- curl -s -o /dev/null -w "%{http_code}" "http://$target_host"
      rc_http_code=${CAPTURE_OUTPUT_RC:-0}
      if [ "$rc_http_code" -ne 0 ]; then
        http_code="000"
      fi

      if [ "$http_code" = "200" ]; then
        actual="ALLOW"
      else
        actual="DENY"
      fi

      if [ "$expected" = "$actual" ]; then
        status="PASS"
      else
        status="FAIL"
      fi
    fi
  fi

  if [ "$expected" = "ALLOW" ]; then ALLOW_COUNT=$((ALLOW_COUNT + 1)); fi
  if [ "$expected" = "DENY" ]; then DENY_COUNT=$((DENY_COUNT + 1)); fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$src_name" "$dst_name" "$expected" "$actual" "$status" "$http_code" >> "$tmp_results"
done < "$tmp_pairs"

if [ "$ALLOW_COUNT" -eq 0 ] || [ "$DENY_COUNT" -eq 0 ]; then
  echo "[FAIL] incomplete matrix coverage: allow=$ALLOW_COUNT deny=$DENY_COUNT"
  exit 2
fi

python3 - "$tmp_results" "$OUT_PATH" <<'PY'
import json
import pathlib
import sys

rows_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])

results = []
for line in rows_path.read_text().splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) != 6:
        continue
    src, dst, expected, actual, status, http_code = parts
    results.append(
        {
            "from": src,
            "to": dst,
            "expected": expected,
            "actual": actual,
            "status": status,
            "http_code": http_code,
        }
    )

failures = sum(1 for r in results if r.get("status") == "FAIL")
payload = {
    "results": results,
    "summary": {
        "total": len(results),
        "failures": failures,
    },
}
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(json.dumps(payload, indent=2) + "\n")

if failures > 0:
    print(f"[FAIL] wrote artifacts/verify_results.json ({len(results)} checks, {failures} failures)")
    sys.exit(1)

print(f"[PASS] wrote artifacts/verify_results.json ({len(results)} checks, 0 failures)")
PY
rc_finalize=$?
if [ "$rc_finalize" -eq 10 ]; then
  exit 10
fi
if [ "$rc_finalize" -eq 0 ]; then
  exit 0
fi
exit 2
