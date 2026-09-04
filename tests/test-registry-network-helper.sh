#!/usr/bin/env bash
# test-registry-network-helper.sh — regression test for registry IPv4 extraction
#
# Ensures the registry network helper picks a single IPv4 address when docker
# reports multiple attached networks.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPBIN="$(mktemp -d)"
trap 'rm -rf "$TMPBIN"' EXIT

cat >"${TMPBIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *'ps --filter name=threadforge-registry --format {{.ID}}'*)
    printf 'registry-container-id\n'
    ;;
  *'inspect registry-container-id --format {{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}'*)
    # Force the helper into the fallback path.
    ;;
  *'inspect registry-container-id --format {{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}'*)
    printf '172.17.0.2\n172.18.0.2\n'
    ;;
  *)
    printf 'unexpected docker invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${TMPBIN}/docker"

output="$(
  PATH="${TMPBIN}:$PATH" \
  bash -c '. scripts/lib/registry_network.sh; resolve_registry_ipv4 registry-container-id'
)"

if [[ "$output" != "172.17.0.2" ]]; then
  echo "[FAIL] expected first IPv4 only, got: ${output}"
  exit 1
fi

echo "[PASS] registry IPv4 helper returns a single network address"
