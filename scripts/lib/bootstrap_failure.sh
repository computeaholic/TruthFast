#!/usr/bin/env bash

fail_bootstrap() {
  printf '[FAIL] BOOTSTRAP_STEP_FAILED: %s\n' "$*" >&2
  exit 2
}
