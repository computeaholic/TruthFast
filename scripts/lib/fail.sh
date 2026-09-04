#!/usr/bin/env bash

fail_policy() {
  echo "[POLICY VIOLATION] $1" >&2
  exit 2
}

fail_system() {
  echo "[SYSTEM ERROR] $1" >&2
  exit 2
}
