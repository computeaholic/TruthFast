
#!/usr/bin/env bash
set -euo pipefail

# Nightly maintenance script
# 1) run format/lint fixes
# 2) run tests
# 3) if fixes were made, open PR and auto-merge when checks pass
# 4) mark stale issues and close very-old issues

cd "$(git rev-parse --show-toplevel)"

DATE=$(date -u +%Y%m%d)
RUN_SUFFIX=${GITHUB_RUN_ID:-$(date -u +%H%M%S)}
BRANCH="chore/nightly-fixes-$DATE-$RUN_SUFFIX"

echo "Running format/lint fixes"
VENV_DIR=".venv-nightly"
if [ ! -d "$VENV_DIR" ]; then
  echo "Creating virtualenv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python"
"$PYTHON" -m pip install --upgrade pip >/dev/null
"$PYTHON" -m pip install -r requirements/runtime.txt -r requirements/dev.txt >/dev/null
"$PYTHON" -m ruff check --fix --exit-zero --output-format json . | tee /tmp/ruff-nightly.json
"$PYTHON" -m black . || true

echo "Running unit tests"
"$PYTHON" -m pytest -q -m "not integration"

# Detect changes
if ! git diff --quiet; then
  echo "Changes detected, creating branch $BRANCH"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git checkout -B "$BRANCH"
  git add -A
  git commit -m "chore(ci): nightly auto-fixes $DATE"
  git push -u origin "$BRANCH"

  # Create PR
  gh pr create --title "chore(ci): nightly auto-fixes $DATE" --body "Automated nightly fixes: formatting and lint auto-fixes." --label "automated" --label "chore" --base main
  # Attempt auto-merge when checks pass
  # Use --fill to use commit body
  gh pr merge --auto --squash --delete-branch || true
else
  echo "No code fixes to commit"
fi

# Stale issue handling
# Label issues with no activity for 30+ days as 'stale'
CUTOFF30=$(date -d '30 days ago' --iso-8601=seconds)
CUTOFF90=$(date -d '90 days ago' --iso-8601=seconds)

# Add stale label to issues updated before 30 days
for num in $(gh issue list --state open --limit 200 --json number,updatedAt --jq '.[] | select(.updatedAt < "'"$CUTOFF30"'" ) | .number'); do
  echo "Labeling issue #$num as stale"
  gh issue edit "$num" --add-label "stale" || true
  gh issue comment "$num" --body "This issue has had no activity in 30+ days. Adding \"stale\" label; it will be auto-closed after 7 days without activity." || true
done

# Close issues labeled stale for >7 days
STABLE_THRESHOLD=$(date -d '7 days ago' --iso-8601=seconds)
for num in $(gh issue list --state open --label stale --limit 200 --json number,updatedAt --jq '.[] | select(.updatedAt < "'"$STABLE_THRESHOLD"'" ) | .number'); do
  echo "Closing stale issue #$num"
  gh issue comment "$num" --body "Closing due to inactivity. Reopen or comment if this should remain open." || true
  gh issue close "$num" || true
done

echo "Nightly maintenance complete"
