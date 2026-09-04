#!/usr/bin/env bash
set -e

kubectl -n agents-lab exec deploy/research-agent -- \
  curl -s -o /dev/null -w "%{http_code}\n" \
  http://writer-agent/write -X POST
