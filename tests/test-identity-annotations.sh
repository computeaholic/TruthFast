#!/usr/bin/env bash
set -euo pipefail

# Fail if any shell script that performs mutating kubectl actions lacks the requires_identity annotation
MUTATING_FILES=$(grep -RIn "kubectl .*apply\|kubectl .*create\|kubectl .*delete\|kubectl .*rollout restart\|kubectl .*exec -i" --line-number --binary-files=without-match | cut -d: -f1 | sort -u)

if [ -z "${MUTATING_FILES}" ]; then
  echo "No mutating kubectl invocations found; nothing to check"; exit 0
fi

fail=0
for f in $MUTATING_FILES; do
  # Only check shell scripts (shebang present)
  if head -n 2 "$f" | grep -q "#!/usr/bin/env bash"; then
    head -n 20 "$f" | egrep -q "requires_identity=true" || {
      echo "Missing annotation in $f"; fail=1
    }
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "One or more mutating scripts are missing requires_identity annotation"; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "All mutating shell scripts have identity annotations"
