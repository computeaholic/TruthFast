###############################################################################
# THREADFORGE — RUNTIME MODULE (V13)
# Purpose:
#   - Bring up platform runtime after infra
#   - Keep runtime idempotent and observable
###############################################################################

RUNTIME_DIR ?= $(REPO_ROOT)/platform/deploy/runtime
RUNTIME_NS ?= threadforge-system

.PHONY: runtime-init runtime-nuke runtime-health runtime-deploy-api runtime-import-api

RUNTIME_DEPLOY_API_ACK ?=

runtime-init:
	$(call info,"🚀 Runtime init (Python runtime, non-Kubernetes)")

	@test -d "$(ROOT)/runtime" || { echo "[FAIL] Missing runtime package: $(ROOT)/runtime"; exit 2; }

	@test -f "$(ROOT)/platform/runtime/pyproject.toml" || { echo "[FAIL] Runtime manifest missing: $(ROOT)/platform/runtime/pyproject.toml"; exit 2; }

	@test -f "$(ROOT)/platform/runtime/VERSION" || { echo "[FAIL] Runtime version not pinned: $(ROOT)/platform/runtime/VERSION"; exit 2; }

	$(call success,"Runtime code validated")
	$(call info,"Runtime is executed via CLI / daemon — no kubectl apply")
	@$(MAKE) observability-enforce
	@$(MAKE) security-enforce
	$(call success,"Runtime init complete")

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
runtime-nuke: core-verify-bins kubeconfig-sync
	@if [ "$(ALLOW_RUNTIME_K8S_CLEANUP)" != "YES" ]; then \
	  echo "[FAIL] Refusing runtime-nuke without ALLOW_RUNTIME_K8S_CLEANUP=YES"; exit 2; \
	fi
	$(call warn,"Removing runtime-associated Kubernetes artifacts only")
	@$(RUN_KUBECTL) delete -n $(RUNTIME_NS) all --all --ignore-not-found=true >/dev/null 2>&1
	@$(RUN_KUBECTL) delete ns $(RUNTIME_NS) --ignore-not-found=true >/dev/null 2>&1
	$(call log-ok,"Runtime-associated K8s artifacts removed (async namespace delete)")

runtime-health:
	$(call log-step,"🩺 Runtime health")

	@set +e; pods="$$( $(RUN_KUBECTL) get pods -n $(RUNTIME_NS) 2>&1 )"; rc=$$?; set -e; \
	if [ $$rc -ne 0 ]; then printf '%s\n' "$$pods" >&2; exit $$rc; fi; \
	printf '%s\n' "$$pods" | grep -q Running || { echo "[FAIL] Runtime pods not healthy"; exit 2; }

	$(call log-ok,"Runtime healthy")

runtime-import-api:
	$(call info,"📤 Pushing ThreadForge API image to internal registry")
	@test -f out/images/threadforge-api.tar || { echo "[FAIL] API image tar not found. Run 'make build-api' first."; exit 2; }
	@skopeo copy --dest-tls-verify=false docker-archive:out/images/threadforge-api.tar:$(API_IMAGE) docker://$(API_IMAGE) >/dev/null || { echo "[FAIL] API image archive push failed: $(API_IMAGE)"; exit 2; }
	$(call success,"API image pushed to internal registry")

# SECONDARY_APPLICATION_TARGET
# This optional FastAPI/OperatorCore surface is not part of native V1 qualification
# and does not own cold-start convergence of its application secrets/configuration.
runtime-deploy-api:
	@echo "[SECONDARY] runtime-deploy-api is NOT_NATIVE_V1_QUALIFIED and NOT_COLD_START_SUPPORTED"
	@if [ "$(RUNTIME_DEPLOY_API_ACK)" != "I_UNDERSTAND_THIS_IS_SECONDARY" ]; then \
	  echo "[FAIL] Secondary target requires RUNTIME_DEPLOY_API_ACK=I_UNDERSTAND_THIS_IS_SECONDARY"; \
	  echo "[FAIL] Provision the documented API secrets and ConfigMaps before invoking this development/compatibility path."; \
	  exit 2; \
	fi
	@$(MAKE) core-verify-bins kubeconfig-sync observability-gate security-gate
	@missing=""; \
	for object in \
	  secret/api-secret \
	  secret/authority-signing-key \
	  configmap/capability-matrix \
	  configmap/intent-registry \
	  configmap/ppit-policy \
	  configmap/identity-policies \
	  configmap/tier-b-aas; do \
	  if ! $(RUN_KUBECTL) -n threadforge get "$$object" >/dev/null 2>&1; then missing="$$missing $$object"; fi; \
	done; \
	if [ -n "$$missing" ]; then \
	  echo "[FAIL] SECONDARY_PREREQUISITES_MISSING:$$missing"; \
	  echo "[FAIL] runtime-deploy-api deliberately does not synthesize application authority or credentials."; \
	  exit 2; \
	fi
	@$(MAKE) runtime-import-api
	$(call info,"🚀 Deploying ThreadForge API to Kubernetes")

	@set +e; ns_out="$$( $(RUN_KUBECTL) get namespace threadforge 2>&1 )"; ns_rc=$$?; set -e; \
	if [ $$ns_rc -ne 0 ]; then \
	  case "$$ns_out" in \
	    *"NotFound"*|*"not found"*) $(RUN_KUBECTL) create namespace threadforge ;; \
	    *) printf '%s\n' "$$ns_out" >&2; exit $$ns_rc ;; \
	  esac; \
	fi

	@$(RUN_KUBECTL) label namespace threadforge istio-injection=enabled --overwrite

	@api_image="$(API_IMAGE)"; \
	api_repo="$${api_image%:*}"; \
	api_tag="$${api_image##*:}"; \
	helm upgrade --install threadforge-api \
	  platform/deploy/services/api \
	  --namespace threadforge \
	  --create-namespace \
	  --set image.repository="$$api_repo" \
	  --set image.tag="$$api_tag" \
	  --set image.pullPolicy=IfNotPresent \
	  --wait --timeout=5m

	$(call success,"ThreadForge API deployed")
	$(call info,"Verify with: kubectl get pods -n threadforge")
