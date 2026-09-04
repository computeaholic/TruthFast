# ==============================================================================
# THREADFORGE — Developer Discipline Plane
# Formatting · Linting · Typing · Security
# Deterministic · Non-runtime · AFRL-grade
# ==============================================================================

.PHONY: format lint typecheck security dev-check dev-fast dev-full

# ------------------------------------------------------------------------------
# FORMAT (AUTO-FIX ONLY — SAFE)
# ------------------------------------------------------------------------------

format:
	@echo "🧹 Formatting codebase..."
	@if [ -x .venv/bin/python ]; then \
		.venv/bin/python -m black .; \
	else \
		python3 -m black .; \
	fi
	@if [ -x .venv/bin/python ]; then \
		.venv/bin/python -m ruff check . --fix; \
	else \
		python3 -m ruff check . --fix; \
	fi
	@if [ -x .venv/bin/python ]; then \
		.venv/bin/python -m sqlfluff fix schemas/postgres; \
		.venv/bin/python -m sqlfluff lint schemas/postgres; \
	else \
		python3 -m sqlfluff fix schemas/postgres; \
		python3 -m sqlfluff lint schemas/postgres; \
	fi
	@echo "✔ Formatting complete"

# ------------------------------------------------------------------------------
# LINT (STATIC)
# ------------------------------------------------------------------------------

lint:
	@echo "🔍 Running Ruff lint checks..."
	@if [ -x .venv/bin/ruff ]; then \
		.venv/bin/ruff check .; \
	else \
		python3 -m ruff check .; \
	fi

# ------------------------------------------------------------------------------
# TYPE CHECKING
# ------------------------------------------------------------------------------

typecheck:
	@echo "[TF] typecheck: running mypy from venv"
	$(CURDIR)/.venv/bin/mypy $(CURDIR)

# ------------------------------------------------------------------------------
# SECURITY (ADVISORY ONLY — NO GATING)
#
# Runs static security analysis tools to inform operators of potential concerns.
# All findings are advisory; no enforcement or blocking occurs.
#
# Tools:
#   - bandit: Static Python security review (built-in)
#   - trufflehog: Secret detection in git history + working tree (via pipx, optional)
#   - semgrep: Semantic pattern analysis for security intent (optional, light mode)
#   - pip-audit: Supply chain vulnerability awareness (optional)
#
# Notes:
#   - trufflehog, semgrep, pip-audit are NOT runtime dependencies
#   - Missing tools degrade gracefully; no CI gating
#   - All findings are advisory; operator judgment is sovereign
#   - Install optional tools: pipx install trufflehog semgrep pip-audit
# ------------------------------------------------------------------------------

security:
	$(call log-step,"🔐 Running Bandit security scan...")
	bandit -r platform/runtime api internal scripts -q || true
	@echo ""
	@echo "📊 Checking for secret leaks with TruffleHog..."
	@if command -v trufflehog >/dev/null 2>&1; then \
		echo "  [TruffleHog] Scanning git history and working tree..."; \
		trufflehog git file:// --max-depth 1000000 --json 2>/dev/null || true; \
		echo "  [TruffleHog] Scan complete (advisory only)"; \
	else \
		echo "  [!] trufflehog not found (optional). Install with: pipx install trufflehog"; \
	fi
	@echo ""
	@echo "🧠 Semantic pattern analysis with Semgrep..."
	@if command -v semgrep >/dev/null 2>&1; then \
		echo "  [Semgrep] Running light security audit patterns..."; \
			semgrep --config=p/security-audit platform/runtime api internal scripts 2>/dev/null || true; \
		echo "  [Semgrep] Scan complete (advisory only)"; \
	else \
		echo "  [!] semgrep not found (optional). Install with: pipx install semgrep"; \
	fi
	@echo ""
	@echo "📦 Supply chain vulnerability awareness with pip-audit..."
	@if command -v pip-audit >/dev/null 2>&1; then \
		echo "  [pip-audit] Checking for known vulnerabilities in dependencies..."; \
		pip-audit --skip-editable 2>/dev/null || true; \
		echo "  [pip-audit] Scan complete (advisory only)"; \
	else \
		echo "  [!] pip-audit not found (optional). Install with: pipx install pip-audit"; \
	fi
	@echo ""
	@echo "✔ Security scan complete (all findings are advisory)"

# ------------------------------------------------------------------------------
# STATIC CORRECTNESS LINTING (ShellCheck + Hadolint)
# Note: These are informational-only checks for static correctness.
# They do NOT perform vulnerability scanning, runtime analysis, or introduce
# security claims. They are intentionally non-fatal and are used for developer
# hygiene only.
# ------------------------------------------------------------------------------

.PHONY: shell-lint docker-lint

shell-lint:
	@echo "🐚 Running ShellCheck (static shell linting)..."
	@shellcheck forgesec/**/*.sh scripts/**/*.sh 2>/dev/null || true
	@echo "✔ ShellCheck completed (informational)"

docker-lint:
	@echo "🐳 Running Hadolint (Dockerfile linting)..."
	@hadolint Dockerfile Dockerfile.* platform/images/**/Dockerfile* forgesec/**/Dockerfile* 2>/dev/null || true
	@echo "✔ Hadolint completed (informational)"

# ------------------------------------------------------------------------------
# COMPOSITE TARGETS
# ------------------------------------------------------------------------------

dev-check: lint typecheck security
	$(call log-ok,"Developer checks complete")

dev-fast: format lint
	$(call log-ok,"Fast dev loop complete")

dev-full: format lint typecheck security shell-lint docker-lint
	$(call log-ok,"AFRL-grade developer gate passed")

.PHONY: test-unit test-integration

test-unit:
	@echo "🧪 Running unit tests (no integration; default)"
	PYTHONPATH="$(ROOT)" .venv/bin/python -m pytest -q -m "not integration"

test-integration:
	@echo "🧪 Running integration tests (opt-in). Set RUN_INTEGRATION=1 to proceed"
	@if [ -z "$${RUN_INTEGRATION:-}" ]; then \
		echo "To run integration tests, set RUN_INTEGRATION=1 and required env vars (e.g., THREADFORGE_INGRESS_URL)"; \
		echo "[ADVISORY-FAIL] non-authoritative path"; exit 0; \
	fi
	PYTHONPATH="$(ROOT)" .venv/bin/python -m pytest -q -m "integration"

# ==============================================================================
# END DEV PLANE
# ==============================================================================
