#!/usr/bin/env bash
set -euo pipefail

mkdir -p site/content/demo

# Copy the approved contract doc into the site demo content
cp docs/contracts/execution_to_value.md site/content/demo/execution_to_value.md

echo "Demo export complete: site/content/demo/"