#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SITE_DIR="${1:-${THREADFORGE_MKDOCS_SITE_DIR:-artifacts/mkdocs-site}}"

PYTHON_BIN="${THREADFORGE_PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if [[ -x "$REPO_ROOT/.venv/bin/python" ]]; then
    PYTHON_BIN="$REPO_ROOT/.venv/bin/python"
  elif [[ -n "${VIRTUAL_ENV:-}" && -x "$VIRTUAL_ENV/bin/python" ]]; then
    PYTHON_BIN="$VIRTUAL_ENV/bin/python"
  else
    PYTHON_BIN="$(command -v python3 || true)"
  fi
fi

if [[ -z "$PYTHON_BIN" ]]; then
  echo "[FAIL] DOCS_STRICT: no Python interpreter available" >&2
  exit 2
fi

if ! "$PYTHON_BIN" -m mkdocs --version >/dev/null 2>&1; then
  echo "[FAIL] DOCS_STRICT: mkdocs dependency missing from the selected Python environment: $PYTHON_BIN" >&2
  exit 2
fi

mkdir -p "$SITE_DIR"
"$PYTHON_BIN" -m mkdocs build --strict --site-dir "$SITE_DIR"
echo "[PASS] docs strict build: $SITE_DIR"
