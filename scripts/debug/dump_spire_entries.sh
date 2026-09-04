#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO_ROOT/artifacts/debug/spire_entries_runtime.json"
SPIRE_SOCKET_PATH="/run/spire/private/spire-server.sock"

mkdir -p "$(dirname "$OUT")"

kubectl -n spire-system exec spire-server-0 -- \
  /opt/spire/bin/spire-server entry show -output json -socketPath "$SPIRE_SOCKET_PATH" \
  > "$OUT"

echo "[debug] wrote runtime entries to $OUT"
