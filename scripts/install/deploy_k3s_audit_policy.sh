#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(dirname "${BASH_SOURCE[0]}")/.."
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
A_DIR="$REPO_DIR/platform/deploy/infra/k3s/audit"
LIVE_PATH="/var/lib/rancher/k3s/server/audit-policy.yaml"

usage(){
  cat <<EOF
Usage: $0 [version]
Deploy a repo-stored audit policy to the live k3s location.
Default version: v1 -> audit-policy.v1.yaml

Examples:
  $0 v1
  $0 v2

This script is idempotent and requires explicit confirmation.
EOF
}

VERSION=${1:-v1}
REPO_FILE="$A_DIR/audit-policy.${VERSION}.yaml"

if [ ! -f "$REPO_FILE" ]; then
  echo "ERROR: Repo file not found: $REPO_FILE" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Repo file: $REPO_FILE"
printf "Repo SHA256: "; sha256sum "$REPO_FILE"

if [ -f "$LIVE_PATH" ]; then
  printf "Live SHA256: "; sudo sha256sum "$LIVE_PATH" || true
else
  echo "Live file does not exist at $LIVE_PATH"
fi

echo
echo "--- DIFF: repo -> live (if live exists) ---"
if [ -f "$LIVE_PATH" ]; then
  sudo diff -u "$LIVE_PATH" "$REPO_FILE" || true
else
  echo "(no live file to diff against)"
fi

# Idempotent: if SHAs match, exit cleanly
if [ -f "$LIVE_PATH" ] && sha256sum "$REPO_FILE" | awk '{print $1}' | grep -q "$(sudo sha256sum "$LIVE_PATH" | awk '{print $1}')"; then
  echo "Repo file and live file are identical. Nothing to do."
  exit 0
fi

# Confirmation
read -r -p "Type APPLY to continue: " CONFIRM
if [ "$CONFIRM" != "APPLY" ]; then
  echo "Abort: confirmation not provided." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Copy
sudo cp "$REPO_FILE" "$LIVE_PATH"
sudo chown root:root "$LIVE_PATH"
sudo chmod 0644 "$LIVE_PATH"

# Sanity check: prevent shipping a mangled file (ensure it looks like an audit Policy)
if ! sudo grep -q "kind: Policy" "$LIVE_PATH"; then
  echo "ERROR: Live file does not appear valid." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

printf "New live SHA256: "; sudo sha256sum "$LIVE_PATH"

echo "NOTE: k3s is not restarted by this script. To apply changes, a controlled restart is required (operator action)."

echo "Done."
