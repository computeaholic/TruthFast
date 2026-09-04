#!/usr/bin/env bash
set -euo pipefail

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

sha_tree() {
  find "$1" -type f -exec sha256sum {} \; | sort
}
