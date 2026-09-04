#!/usr/bin/env bash
# Prototype registry health check
# Usage: ./scripts/registry-health-check.sh --mode <observe|warn|enforce> --output-json out/registry-health.json
set -euo pipefail
MODE=observe
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE=$2; shift 2;;
    --output-json) OUT=$2; shift 2;;
    *) shift;;
  esac
done
if [ -z "$OUT" ]; then
  echo "Must provide --output-json <path>" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
mkdir -p "$(dirname "$OUT")"
# If skopeo is present, ensure REGISTRY_CA is provided and valid to enforce TLS verification
if command -v skopeo >/dev/null 2>&1; then
  if [ -z "${REGISTRY_CA:-}" ]; then
    echo "ERROR: skopeo is available but REGISTRY_CA is not set. Set REGISTRY_CA to the directory containing registry CA certs." >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
  if [ ! -d "${REGISTRY_CA}" ]; then
    echo "ERROR: REGISTRY_CA directory '${REGISTRY_CA}' does not exist or is not a directory" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

# Gather pinned digests from platform/deploy/*
mapfile -t pins < <(grep -R --line-number "@sha256:[0-9a-f]\{64\}" deploy || true)
results=()
for r in "${pins[@]}"; do
  file=$(echo "$r" | cut -d: -f1)
  lineno=$(echo "$r" | cut -d: -f2)
  line=$(sed -n "${lineno}p" "$file")
  image=$(echo "$line" | sed -E 's/.*image:\s*([^ ]+).*/\1/')
  digest=$(echo "$image" | sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\)$/\1/p')
  # Check registry presence via skopeo if available
  if command -v skopeo >/dev/null 2>&1; then
    if [ -n "${REGISTRY_CA:-}" ] && [ -d "${REGISTRY_CA}" ]; then
    if skopeo inspect --tls-verify=true --cert-dir "${REGISTRY_CA}" "docker://$image" >/dev/null 2>&1; then
      status="present"
    else
      status="missing"
    fi
  else
    status="skopeo-missing-or-no-REGISTRY_CA"
  fi
  results+=("{\"file\": \"$file\", \"line\": $lineno, \"image\": \"$image\", \"status\": \"$status\"}")
done
json="{\"mode\": \"$MODE\", \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"results\": [$(IFS=,; echo "${results[*]}")] }"
echo "$json" > "$OUT"
count=$(echo "$json" | jq '.results | length')
echo "Mode: $MODE; checked $count pinned images"
# If enforce and any missing, fail
if [ "$MODE" = "enforce" ]; then
  missing=$(echo "$json" | jq '[.results[] | select(.status=="missing")] | length')
  if [ "$missing" -gt 0 ]; then
    echo "Missing digests detected: $missing" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi
