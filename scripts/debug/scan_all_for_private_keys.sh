#!/usr/bin/env bash
set -euo pipefail

# FIX 5: Scan all tracked files for private key markers and fail if any matches found.
# Explicit pattern — only RSA/EC/DSA/OPENSSH/PKCS#8 private keys and PGP private key blocks.
# ALLOWLISTED (not matched): -----BEGIN CERTIFICATE----- — the repo contains
# X.509 proof artifacts (trust roots, CA chains). Certificate data is not a secret.
PATTERN='-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY BLOCK-----'
EXCLUDES='^\.venv|^\.venv_test|^\.venv_check|^\.venv-sweep|^node_modules/|^frontend/node_modules/|^\.git/|^\.signer/|^vendor/'

files=$(git ls-files)
if [ -z "$files" ]; then
  echo "No tracked files to scan."
  exit 0
fi

rc=0
while IFS= read -r f; do
  if [[ -z "$f" ]]; then
    continue
  fi
  if [[ "$f" =~ $EXCLUDES ]]; then
    continue
  fi
  if [ ! -f "$f" ]; then
    continue
  fi
  if grep -I -n -E "$PATTERN" -- "$f" >/dev/null 2>&1; then
    echo "ERROR: potential private key marker found in file: $f"
    grep -n -E "$PATTERN" -- "$f" || true
    rc=1
  fi
done <<< "$files"

if [ $rc -ne 0 ]; then
  echo "Potential private key markers detected in tracked files. Please remove private keys and regenerate them." >&2
  exit 2
fi

echo "No private key markers found in tracked files."
exit 0
