.PHONY: cleanup-tests cleanup-debug
# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
cleanup-tests:
	@echo "Running cleanup-tests (dry-run). To perform deletions set CONFIRM=true and re-run."
	@NAMESPACE="$(NAMESPACE)" CONFIRM="$(CONFIRM)" ./scripts/cleanup/cleanup-tests.sh

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
cleanup-debug:
	@echo "Running cleanup-debug (dry-run). To perform deletions set CONFIRM=true and re-run."
	@CONFIRM="$(CONFIRM)" ./scripts/cleanup/cleanup-debug.sh

# Example: make cleanup-tests CONFIRM=true
# Example: make cleanup-debug CONFIRM=true
