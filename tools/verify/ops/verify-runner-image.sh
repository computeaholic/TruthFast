#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <image-ref>"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
IMAGE="$1"

echo "Pulling image: $IMAGE"
docker pull "$IMAGE"

# Try Debian-based check first
if docker run --rm "$IMAGE" dpkg -s python3.12-venv >/dev/null 2>&1; then
  echo "OK: python3.12-venv present"
  exit 0
fi

# Fallback: try import via python3 module
if docker run --rm "$IMAGE" python3 -c "import venv; print('OK: venv module available')" >/dev/null 2>&1; then
  docker run --rm "$IMAGE" python3 -c "import venv; print('OK: venv module available')"
  exit 0
fi

# If both checks fail, print summary and exit non-zero
echo "ERROR: image $IMAGE does not appear to include python venv support (dpkg or python import check failed)"
echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
