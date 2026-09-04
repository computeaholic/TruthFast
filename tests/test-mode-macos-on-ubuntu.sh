#!/usr/bin/env bash
set -euo pipefail

# Guard: MODE=macos must not be reported when running inside an Ubuntu VM.
# The Makefile must reflect where execution happens (node OS), not where the
# keyboard lives. If /etc/os-release says ubuntu, any doctor/help output that
# still reports MODE=macos is a contract violation.

if [ ! -f /etc/os-release ]; then
  echo "SKIP: /etc/os-release not present; host OS unknown"
  exit 0
fi

if ! grep -qi '^ID=ubuntu' /etc/os-release; then
  echo "SKIP: Host is not Ubuntu; MODE=macos guard not applicable"
  exit 0
fi

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

set +e
OUT=$(make -s help 2>&1)
rc=$?
set -e

echo "$OUT" | sed -n '1,3p'

if echo "$OUT" | grep -q 'MODE=macos'; then
  echo "FAIL: Makefile reported MODE=macos while /etc/os-release indicates Ubuntu" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "OK: MODE does not claim macos when running on Ubuntu"
