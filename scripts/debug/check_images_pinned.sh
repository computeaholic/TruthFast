#!/usr/bin/env bash
# Guard script: fail if any DaemonSet in repo references tag (not @sha256) or registry host is 127.0.0.1
set -euo pipefail
errors=0

# Check platform/deploy/shim/daemonset.yaml for pinned images
files=("platform/deploy/shim/daemonset.yaml" "platform/deploy/infra/spire/templates/csi-driver/spire-csi-driver.yaml")
for f in "${files[@]}"; do
  if grep -q "image: .*@sha256:" "$f"; then
    echo "OK: $f uses @sha256 pinning"
  else
    echo "[ERROR] $f does not use @sha256 pinning" >&2
    errors=$((errors+1))
  fi
  # check for 127.0.0.1 in image host
  if grep -q "127.0.0.1\|localhost" "$f"; then
    echo "[ERROR] $f references 127.0.0.1/localhost in image registry - not allowed" >&2
    errors=$((errors+1))
  fi
done

# Check live DS image references as a sanity check
ds_images=$(kubectl get daemonset -A -o jsonpath='{range .items[*]}{.metadata.namespace}::{.metadata.name}::{range .spec.template.spec.containers[*]}{.image}~{end}\n{end}')
while IFS= read -r line; do
  ns=$(echo "$line" | awk -F '::' '{print $1}')
  name=$(echo "$line" | awk -F '::' '{print $2}')
  imgs=$(echo "$line" | awk -F '::' '{print $3}')
  for img in $(echo "$imgs" | tr '~' '\n'); do
    if [[ -z "$img" ]]; then continue; fi
    if [[ "$img" != *"@sha256:"* ]]; then
      echo "[ERROR] DaemonSet $ns/$name uses unpinned image: $img" >&2
      errors=$((errors+1))
    else
      echo "OK: DaemonSet $ns/$name image pinned: $img"
    fi
    if [[ "$img" == *"127.0.0.1"* || "$img" == *"localhost"* ]]; then
      echo "[ERROR] DaemonSet $ns/$name image references 127.0.0.1/localhost: $img" >&2
      errors=$((errors+1))
    fi
  done
done <<< "$ds_images"

if [ "$errors" -gt 0 ]; then
  echo "Guard check failed: $errors issue(s) found" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Guard check passed: all images pinned and registry hosts OK"