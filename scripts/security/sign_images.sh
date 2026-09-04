echo "[sign_images] signing ${#signed_images[@]} image references"
#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper that forwards to the canonical, authoritative implementation
# at scripts/supply_chain/sign_images.sh. This wrapper must not implement
# signing logic or alter exit codes; it only validates the canonical script
# exists, prints an informational forwarding message, and execs the
# canonical script so its exit code is preserved.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$REPO_ROOT/scripts/supply_chain/sign_images.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "[FAIL] canonical sign_images not found: $CANONICAL" >&2
  exit 10
fi

echo "[INFO] forwarding to canonical supply_chain implementation: $CANONICAL" >&2
exec "$CANONICAL" "$@"
