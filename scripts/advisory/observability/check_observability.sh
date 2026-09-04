#!/usr/bin/env bash
set -euo pipefail

NS="threadforge-system"
PROBE_IMG="registry.threadforge.local:30500/mirror/docker.io/curlimages/curl@sha256:4a3396ae573c44932d06ba33f8696db4429c419da87cbdc82965ee96a37dd0af"

echo "[check_observability] verifying observability deployments"
kubectl -n "$NS" get deploy prometheus
kubectl -n "$NS" get deploy grafana

if kubectl -n "$NS" get deploy loki >/dev/null 2>&1; then
  kubectl -n "$NS" get svc loki
fi

if kubectl -n "$NS" get deploy kiali >/dev/null 2>&1; then
  kubectl -n "$NS" get svc kiali
fi

echo "[check_observability] probing prometheus and grafana endpoints"
kubectl -n "$NS" run obs-probe --rm -i --restart=Never --image="$PROBE_IMG" --command -- sh -c "curl -fsS http://prometheus:9090/-/ready >/dev/null && curl -fsS http://grafana:3000/api/health >/dev/null"

echo "[check_observability] PASS"
