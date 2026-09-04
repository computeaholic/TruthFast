#!/usr/bin/env bash
set -euo pipefail

# Detect private key PEM markers in changed files only.
# Scans either staged files (pre-commit) or the diff between origin/$GITHUB_BASE_REF and HEAD (CI PR check).

PATTERN='-----BEGIN[[:space:]]+(OPENSSH[[:space:]]+)?[A-Z ]*PRIVA[[:space:]]*TE KEY-----|PRIVA[[:space:]]*TE KEY BLOCK|-----BEGIN PGP PRIVA[[:space:]]*TE KEY BLOCK-----'
EXCLUDES='^\.venv|^\.venv_test|^\.venv_check|^\.venv-sweep|^node_modules/|^frontend/node_modules/|^\.git/|^\.signer/|^\.venv/|^vendor/|^\.venv_|^\.venv-'

# Determine files to scan
if [ -n "${GITHUB_BASE_REF:-}" ]; then
  # Running in PR CI environment
  git fetch origin "$GITHUB_BASE_REF" --quiet || true
  files=$(git diff --name-only "origin/${GITHUB_BASE_REF}...HEAD" || true)
else
  # Running as pre-commit: scan staged added/modified files
  files=$(git diff --cached --name-only --diff-filter=ACM || true)
fi

if [ -z "$files" ]; then
  echo "No changed files to scan."
  exit 0
fi

rc=0
while IFS= read -r f; do
  # skip directories and excluded paths
  if [[ -z "$f" ]] || [[ "$f" =~ ^$ ]] ; then
    continue
  fi
  if [[ "$f" =~ $EXCLUDES ]]; then
    continue
  fi
  # Only regular files
  if [ ! -f "$f" ]; then
    continue
  fi
  # Binary files are skipped (grep -I)
  if grep -I -n -E "$PATTERN" -- "$f" >/dev/null 2>&1; then
    echo "ERROR: potential private key marker found in file: $f"
    echo "--- match context ---"
    grep -n -E "$PATTERN" -- "$f" || true
    rc=1
  fi
done <<< "$files"

if [ $rc -ne 0 ]; then
  echo "Potential private key markers detected. Please remove private keys from the commit or contact security." >&2
  exit 2
fi

echo "No private key markers found in changed files."
exit 0
