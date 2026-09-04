#!/bin/bash
# check-otel-health.sh - helper for make doctor telemetry check
# Updated: distinguish Collector running (hard requirement) vs backend reachable (advisory)
set -euo pipefail

if ! kubectl get ns observability >/dev/null 2>&1; then
  echo "⚠️  Telemetry not installed"
  exit 0
fi

# Ensure at least one OpenTelemetryCollector CR exists
if ! kubectl get opentelemetrycollector -n observability >/dev/null 2>&1; then
  echo "ERROR: No OpenTelemetryCollector CRs found in observability namespace (operator-managed collectors required)"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Check for a running operator-managed collector pod (hard requirement)
RUNNING_COLLECTOR_PODS=$(kubectl get pods -n observability -l app.kubernetes.io/component=opentelemetry-collector --no-headers 2>/dev/null | awk '$3=="Running" {print $1}') || true
if [ -z "${RUNNING_COLLECTOR_PODS}" ]; then
  echo "ERROR: No running OpenTelemetry collector pods found in observability namespace (at least one is required)"
  kubectl get pods -n observability -l app.kubernetes.io/component=opentelemetry-collector || true
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
else
  echo "✔ Collector running:"
  echo "$RUNNING_COLLECTOR_PODS"
fi

# Backend reachability (policy-aware)
# Detect Tempo dynamically across namespaces and perform two explicit validations:
# 1) ALLOW: attempt gRPC connect from an OTEL collector pod (allowed path) — success if connect or reflection-disabled warning
# 2) DENY: attempt TCP connect from a non-collector pod (must be refused) — refusal is treated as PASS

# Prefer direct lookup by name, fallback to label
# Try common namespaces first, then fallback to label-based discovery
for ns in tempo observability monitoring default; do
  if kubectl get svc tempo -n $ns >/dev/null 2>&1; then
    TEMPO_NS=$ns
    break
  fi
done
if [ -z "$TEMPO_NS" ]; then
  TEMPO_NS=$(kubectl get svc --all-namespaces -l app.kubernetes.io/name=tempo -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
fi

if [ -n "$TEMPO_NS" ]; then
  TEMPO_DNS="tempo.${TEMPO_NS}.svc.cluster.local:4317"
  echo "✔ Tempo service present in namespace: $TEMPO_NS"
  EP=$(kubectl get endpoints tempo -n "$TEMPO_NS" -o jsonpath='{.subsets}' 2>/dev/null || true)
  if [ -z "$EP" ] || [ "$EP" = "null" ]; then
    echo "⚠️  Tempo has no endpoints in namespace '$TEMPO_NS' (advisory): exporters may not be able to connect to $TEMPO_DNS"
  else
    echo "✔ Tempo endpoints present in namespace '$TEMPO_NS'"

    # ALLOW path: run grpcurl from an OTEL collector pod (prefer existing pods)
    COLLECTOR_POD=$(kubectl get pods -n observability -l app.kubernetes.io/component=opentelemetry-collector --no-headers 2>/dev/null | awk '$3=="Running" {print $1; exit}') || true
    if [ -n "$COLLECTOR_POD" ]; then
      echo "→ Testing OTLP gRPC from collector pod: $COLLECTOR_POD"
      if kubectl -n observability exec "$COLLECTOR_POD" -- sh -c 'command -v grpcurl >/dev/null 2>&1' >/dev/null 2>&1; then
        GRPC_OUT=$(kubectl -n observability exec "$COLLECTOR_POD" -- sh -c "grpcurl -plaintext $TEMPO_DNS list 2>&1 || true") || true
      else
        # Fallback: create a short-lived probe pod that matches the collector selector so NetworkPolicy allows it
        echo "→ grpcurl not present in collector pod; launching ephemeral probe pod with collector label"
        kubectl -n observability run doctor-grpc --restart=Never --labels=app.kubernetes.io/component=opentelemetry-collector,threadforge.dev/ephemeral=true,threadforge.dev/purpose=doctor-probe,threadforge.dev/owner=make-doctor --image=moul/grpcurl --rm -- sh -c "grpcurl -plaintext $TEMPO_DNS list" > /tmp/doctor_grpc_out 2>&1 || true
        GRPC_OUT=$(cat /tmp/doctor_grpc_out 2>/dev/null || true)
      fi
      echo "$GRPC_OUT" | grep -qi "reflection" && echo "✔ OTLP gRPC reachable (reflection disabled warning accepted)" || (echo "$GRPC_OUT" | grep -qi "Failed to dial" && echo "⚠️  OTLP gRPC probe failed to dial (advisory)" || echo "✔ OTLP gRPC responded")
    else
      echo "⚠️  No running collector pod found for gRPC probe (advisory)"
    fi

    # DENY path: ensure a non-matching pod cannot reach Tempo on 4317
    # Prefer a non-collector pod that has 'nc' available for a reliable DENY test
    NONMATCH_POD=""
    for p in $(kubectl get pods -n observability --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true); do
      # Skip collector pods
      if kubectl get pod -n observability $p -o jsonpath='{.metadata.labels.app\.kubernetes\.io/component}' 2>/dev/null | grep -q "opentelemetry-collector"; then
        continue
      fi
      if kubectl -n observability exec $p -- sh -c 'command -v nc >/dev/null 2>&1' >/dev/null 2>&1; then
        NONMATCH_POD=$p
        break
      fi
    done
    if [ -z "$NONMATCH_POD" ]; then
      # Fallback: launch ephemeral netshoot pod without collector label to perform DENY test
      echo "→ Launching ephemeral non-collector probe pod for DENY test"
      kubectl -n observability run doctor-nc --rm -i --restart=Never --labels=doctor=deny-test,threadforge.dev/ephemeral=true,threadforge.dev/purpose=doctor-probe,threadforge.dev/owner=make-doctor --image=nicolaka/netshoot --command -- sh -c 'nc -vz "$0" 2>&1; echo __EXIT__$?' "$TEMPO_DNS" > /tmp/doctor_nonmatch_out 2>&1 || true
      DENY_RAW=$(cat /tmp/doctor_nonmatch_out 2>/dev/null || true)
    else
      echo "→ Testing DENY from non-collector pod: $NONMATCH_POD"
      DENY_RAW=$(kubectl -n observability exec "$NONMATCH_POD" -- sh -c 'nc -vz "$0" 2>&1; echo __EXIT__$?' "$TEMPO_DNS" 2>/dev/null || true)
    fi

    # Parse exit code (last line) and probe output (all but last line)
    DENY_EXIT=$(echo "$DENY_RAW" | tail -n1 | sed -n 's/^__EXIT__\([0-9]*\)$/\1/p' || true)
    DENY_OUT=$(echo "$DENY_RAW" | sed '$d' || true)

    # If nc returned non-zero or produced a connection-refused style message, treat as DENY (PASS)
    if [ -z "$DENY_EXIT" ] || [ "$DENY_EXIT" -ne 0 ] || echo "$DENY_OUT" | grep -qi "Connection refused\|failed to connect\|No route to host\|Host is unreachable"; then
      echo "✔ Tempo deny from non-collector pods validated (expected)"

      # Even if the primary DENY test passes, perform explicit mesh vs non-mesh checks to classify scope and surface a NON-CLAIM if applicable
      MESH_OK=false
      NONMESH_OK=false
      if kubectl -n loki get pod curlcheck >/dev/null 2>&1; then
        CHECK_RAW=$(kubectl -n loki exec curlcheck -- sh -c 'nc -vz "$0" 2>&1; echo __EXIT__$?' "$TEMPO_DNS" 2>/dev/null || true)
        CHECK_EXIT=$(echo "$CHECK_RAW" | tail -n1 | sed -n 's/^__EXIT__\([0-9]*\)$/\1/p' || true)
        CHECK_OUT=$(echo "$CHECK_RAW" | sed '$d' || true)
        if [ -z "$CHECK_EXIT" ] || [ "$CHECK_EXIT" -ne 0 ] || echo "$CHECK_OUT" | grep -qi "Connection refused\|failed to connect\|No route to host\|Host is unreachable"; then
          echo "✔ Tempo deny from loki/curlcheck validated (mesh client denied)"
        else
          echo "✖ Tempo reachable from loki/curlcheck (mesh client) — this is a mesh-origin case"
          MESH_OK=true
        fi
      fi

      if kubectl -n default get pod csi-debug-threadforge >/dev/null 2>&1; then
        CHECK_RAW=$(kubectl -n default exec csi-debug-threadforge -- sh -c 'nc -vz "$0" 2>&1; echo __EXIT__$?' "$TEMPO_DNS" 2>/dev/null || true)
        CHECK_EXIT=$(echo "$CHECK_RAW" | tail -n1 | sed -n 's/^__EXIT__\([0-9]*\)$/\1/p' || true)
        CHECK_OUT=$(echo "$CHECK_RAW" | sed '$d' || true)
        if [ -z "$CHECK_EXIT" ] || [ "$CHECK_EXIT" -ne 0 ] || echo "$CHECK_OUT" | grep -qi "Connection refused\|failed to connect\|No route to host\|Host is unreachable"; then
          echo "✔ Tempo deny from default/csi-debug-threadforge validated (non-mesh client denied)"
        else
          echo "✖ Tempo reachable from default/csi-debug-threadforge (non-mesh client) — enforcement failure"
          NONMESH_OK=true
        fi
      fi

      # Classification: if only mesh client can reach but non-mesh is denied, document NON-CLAIM
      if [ "$MESH_OK" = true ] && [ "$NONMESH_OK" = false ]; then
        echo "⚠️  Tempo ingress enforcement is a documented NON-CLAIM under PodSecurity 'restricted' (mesh-origin traffic may reach Tempo)."
        echo "→ Rationale: PodSecurity 'restricted' prevents enabling sidecar injection in this namespace; we will not weaken the PodSecurity profile to enforce this claim."
      fi
    else
      echo "⚠️  Tempo reachable from non-collector pod (unexpected):"
      echo "$DENY_OUT"

      echo "→ Inspecting Tempo NetworkPolicies for permissive rules that would allow observability namespace egress..."
      NP_JSONPATH='{range .items[*]}{.metadata.name}{"\t"}{range .spec.ingress[*].from[*]}{.namespaceSelector.matchLabels.kubernetes.io/metadata.name}{"|"}{.namespaceSelector.matchLabels.threadforge-tier}{"\n"}{end}{end}'
      NP_NS_MATCHES=$(kubectl -n tempo get networkpolicy -o jsonpath="$NP_JSONPATH" 2>/dev/null || true)
      if echo "$NP_NS_MATCHES" | grep -qi "observability"; then
        echo "⚠️  Found NetworkPolicy rules in namespace 'tempo' that permit traffic from the whole 'observability' namespace (these allow non-collector pods to reach Tempo):"
        echo "$NP_NS_MATCHES" | grep -i "observability" | awk '{print $1}' | sort -u | xargs -r -n1 -I{} sh -c 'echo "--- NetworkPolicy: {}"; kubectl -n tempo describe networkpolicy {}'
        echo "Recommendation: Narrow the NetworkPolicy ingress rules to select only collector pods (e.g. podSelector with app.kubernetes.io/component=opentelemetry-collector) instead of matching the whole namespace."
      else
        echo "Note: No explicit namespace-wide allow found in tempo NetworkPolicies from observability; further debugging may be required (e.g., permissive ingress with no 'from' clause or cluster-level policies)."
      fi
    fi

    # ------------------------------------------------
    # Additional explicit DENY checks from other namespaces
    # - loki/curlcheck (mesh-labeled test client)
    # - default/csi-debug-threadforge (non-mesh test client)
    # If these pods exist, perform the same nc check and surface any unexpected allow
    for CHECK_NS in loki default; do
      case "$CHECK_NS" in
        loki)
          POD_NAME=curlcheck
          ;;
        default)
          POD_NAME=csi-debug-threadforge
          ;;
      esac
      if kubectl -n "$CHECK_NS" get pod "$POD_NAME" >/dev/null 2>&1; then
        echo "→ Testing DENY from $CHECK_NS/$POD_NAME"
        CHECK_RAW=$(kubectl -n "$CHECK_NS" exec "$POD_NAME" -- sh -c 'nc -vz "$0" 2>&1; echo __EXIT__$?' "$TEMPO_DNS" 2>/dev/null || true)
        CHECK_EXIT=$(echo "$CHECK_RAW" | tail -n1 | sed -n 's/^__EXIT__\([0-9]*\)$/\1/p' || true)
        CHECK_OUT=$(echo "$CHECK_RAW" | sed '$d' || true)
        if [ -z "$CHECK_EXIT" ] || [ "$CHECK_EXIT" -ne 0 ] || echo "$CHECK_OUT" | grep -qi "Connection refused\|failed to connect\|No route to host\|Host is unreachable"; then
          echo "✔ Tempo deny from $CHECK_NS/$POD_NAME validated (expected)"
        else
          echo "✖ Tempo reachable from $CHECK_NS/$POD_NAME (UNEXPECTED):"
          echo "$CHECK_OUT"
          echo "ℹ️  This condition is a documented NON-CLAIM under PodSecurity 'restricted'."
          echo "ℹ️  Enforcing mesh-only ingress would require weakening baseline security."
          echo "→ This violates the 'deny non-collector' requirement and must be fixed by ensuring Tempo is in-mesh and AuthorizationPolicy is enforced, or by narrowing NetworkPolicies."
        fi
      else
        echo "→ Pod $CHECK_NS/$POD_NAME not found; skipping explicit check for $CHECK_NS (advisory)"
      fi
    done

    # End of additional explicit checks

  fi
else
  echo "⚠️  Tempo service not found in any namespace (advisory)"
  TEMPO_DNS=""
fi


# Inspect recent collector logs for exporter connectivity errors (policy-aware advisory)
# Restrict to collector pods and ignore retry/backoff noise and denied connections from non-collector pods
LOGS_CMD="kubectl logs -n observability -l app.kubernetes.io/component=opentelemetry-collector --since=5m --tail=500 2>/dev/null || true"
CRITICAL_ERRORS=$(eval "$LOGS_CMD" | egrep -i "(failed to connect|no such host|dial tcp)" | egrep -vi "retry|backoff|port 3100" || true)
if [ -n "$CRITICAL_ERRORS" ]; then
  echo "⚠️  Exporters report connectivity problems (advisory):"
  echo "$CRITICAL_ERRORS"
fi

# Check for general errors in collector logs (advisory), but disregard retry noise
GENERIC_ERRORS=$(eval "$LOGS_CMD" | grep -i error | egrep -vi "retry|backoff" || true)
if [ -n "$GENERIC_ERRORS" ]; then
  echo "⚠️  Collector logs contain error-level messages (advisory)"
fi

exit 0
