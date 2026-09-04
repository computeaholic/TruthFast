#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[control-plane] compatibility wrapper delegating to canonical convergence gate"
exec bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" "$@"
