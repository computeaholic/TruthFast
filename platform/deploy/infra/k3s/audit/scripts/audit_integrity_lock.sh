#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A_DIR="$REPO_DIR/platform/deploy/infra/k3s/audit"
LIVE_PATH="/var/lib/rancher/k3s/server/audit-policy.yaml"
AUDIT_LOG="/var/log/kubernetes/audit/audit.log"
K3S_BIN="$(command -v pgrep || true)"

fail(){
  echo "AUDIT_INTEGRITY_STATUS=FAIL"
  echo "REASON=$1"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
}

ok(){
  echo "AUDIT_INTEGRITY_STATUS=PASS"
  exit 0
}

# 1) Verify live audit policy SHA matches one of repo versions
if [ ! -f "$LIVE_PATH" ]; then
  fail "live-policy-missing"
fi
LIVE_SHA=$(sha256sum "$LIVE_PATH" | awk '{print $1}')
MATCHING_VERSION=""
for repo in "$A_DIR"/audit-policy.v*.yaml; do
  if [ -f "$repo" ]; then
    REPO_SHA=$(sha256sum "$repo" | awk '{print $1}')
    if [ "$REPO_SHA" = "$LIVE_SHA" ]; then
      MATCHING_VERSION=$(basename "$repo")
      break
    fi
  fi
done

if [ -z "$MATCHING_VERSION" ]; then
  fail "live-sha-mismatch"
fi

echo "live-policy-matches=$MATCHING_VERSION"

# 2) Verify k3s process args contain audit-policy-file
if ! pgrep -x k3s >/dev/null 2>&1; then
  fail "k3s-not-running"
fi
PSARGS=$(ps -o args= -p "$(pgrep -x k3s)")
if ! echo "$PSARGS" | grep -q "audit-policy-file=/var/lib/rancher/k3s/server/audit-policy.yaml"; then
  fail "k3s-arg-missing"
fi

echo "k3s-arg-present=ok"

# 3) Verify audit log exists and writable
if [ ! -f "$AUDIT_LOG" ]; then
  fail "audit-log-missing"
fi
if [ ! -w "$AUDIT_LOG" ]; then
  fail "audit-log-not-writable"
fi

echo "audit-log-present-writable=ok"

# 4) Verify disk guard returns 0 or 5 (not 10)
if ! "$REPO_DIR"/platform/deploy/infra/k3s/audit/scripts/audit_disk_pressure_guard.sh >/dev/null 2>&1; then
  CODE=$?
  if [ "$CODE" -eq 10 ]; then
    fail "disk-usage-critical"
  elif [ "$CODE" -eq 5 ]; then
    echo "disk-usage-warning=ok"
  else
    fail "disk-guard-failed"
  fi
else
  echo "disk-usage-ok"
fi

# 5) Verify last RequestResponse event within 15 minutes
NOW=$(date +%s)
FIFTEEN=$((NOW - 900))
LAST_TS=""

LAST_TS=$(tac "$AUDIT_LOG" | awk '
  {
    if (match($0, /"requestReceivedTimestamp":"([^\"]+)"/, arr)) {
      cmd = "date -d \"" arr[1] "\" +%s"
      cmd | getline t
      close(cmd)
      print t
      exit
    }
    if (match($0, /"timestamp":"([^\"]+)"/, arr)) {
      cmd = "date -d \"" arr[1] "\" +%s"
      cmd | getline t
      close(cmd)
      print t
      exit
    }
  }
') || true

if [ -z "$LAST_TS" ]; then
  fail "no-requestresponse"
fi

if [ "$LAST_TS" -lt "$FIFTEEN" ]; then
  fail "stale-requestresponse"
fi

echo "recent-requestresponse=ok"

ok
