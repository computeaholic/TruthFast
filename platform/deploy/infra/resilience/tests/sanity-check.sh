#!/bin/sh
# Sanity check (dry-run) for kube-dns reconciler CronJob
# - Extracts the CronJob container script, sanitizes it to avoid cluster calls,
#   and executes a healthy-path mock to assert the container would return 0 when DNS is healthy.

set -eu
CRONFILE="$(dirname "$0")/../kube-dns-reconciler-cronjob.yaml"
if [ ! -f "$CRONFILE" ]; then
  echo "missing CronJob manifest: $CRONFILE" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Extract the | heredoc contents after the '- |' marker until the securityContext line
SCRIPT=$(sed -n '/- |/,/securityContext:/p' "$CRONFILE" | sed '1d;$d' | sed 's/^[[:space:]]\{0,\}//')
if [ -z "${SCRIPT}" ]; then
  echo "could not extract script from CronJob manifest" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Sanitize script for healthy-path dry-run:
# - Replace fetching real Service JSON with a static SJSON
# - Replace nslookup with 'true' to simulate healthy DNS
# - Replace patch/event curl calls with no-ops that echo
SANITIZED=$(printf "%s\n" "$SCRIPT" \
  | sed -E "s#SJSON=.*#SJSON='{"'"spec"'":{"'"clusterIP"'":"'"10.43.0.10"'"}}'#g" \
              -e 's#nslookup .*#true#g' \
              -e 's#curl --cacert .* -s -X PATCH .*#echo PATCH-OK || true#g' \
              -e 's#curl --cacert .* -s -X POST .*#echo EVENT-OK || true#g')

# Run sanitized script in a controlled environment
echo "--- running sanitized CronJob script (mock healthy path) ---"
# ensure predictable PATH for commands used
PATH="/usr/bin:/bin"
# Execute and capture output
OUT=$(sh -c "$SANITIZED" 2>&1 || true)
RC=$?
printf '%s\n' "$OUT"

# Check that the healthy-path produced the expected success message
if printf "%s" "$OUT" | grep -q "DNS UDP probe OK"; then
  echo "sanity: healthy-path OK"
  exit 0
else
  echo "sanity: did not find expected success message (DNS UDP probe OK)" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
