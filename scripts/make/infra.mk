###############################################################################
# THREADFORGE — INFRA MODULE (V13)
# Purpose:
#   - Bring up infra in a deterministic order
#   - Idempotent helm installs
###############################################################################

INFRA_DIR ?= $(REPO_ROOT)/platform/deploy/infra
SPIRE_NS ?= spire-system
ISTIO_NS ?= istio-system

define helm_uninstall_or_absent
	@set +e; output="$$( $(RUN_HELM) uninstall $(1) -n $(2) 2>&1 )"; rc=$$?; set -e; \
	if [ $$rc -ne 0 ]; then \
	  case "$$output" in \
	    *"release: not found"*|*"not found"*) \
	      echo "[INFO] $(1) already absent from $(2)"; \
	      ;; \
	    *) \
	      printf '%s\n' "$$output" >&2; \
	      exit $$rc; \
	      ;; \
	  esac; \
	fi
endef

.PHONY: bootstrap-preflight infra-bootstrap infra-bootstrap-runtime-image-pinning bootstrap-verify cluster-reset cluster-nuke ci-cluster-reset native-host-contract-verify host-trust-prime host-trust-verify infra-nuke spire-install spire-nuke istio-core-install istio-install istio-nuke namespaces-install infra-observability-install prometheus-crds-install notifier-install gateway-install

bootstrap-preflight:
	@python3 scripts/infra/bootstrap_preflight.py

bootstrap-converged: prereq-check
	@bash scripts/lib/ensure_cluster.sh
	@bash scripts/verify/verify_bootstrap_converged.sh
	$(call log-ok,"Bootstrap convergence verified")

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
namespaces-install:
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/namespaces.yaml
	$(call log-ok,"Namespaces ready")

###############################################################################
# infra-bootstrap (Identity plane first)
###############################################################################
# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
infra-bootstrap: prereq-check
	@set -euo pipefail; \
		preflight_log="$$(mktemp)"; \
		trap 'rm -f "$$preflight_log"' EXIT; \
		if ! $(MAKE) bootstrap-preflight >"$$preflight_log" 2>&1; then \
			cat "$$preflight_log" >&2; \
			exit 2; \
		fi
	@if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then \
		CI_RUNNER_CERT_PHASE="infra-bootstrap" bash scripts/ci/runner_pretrust_gate.sh --phase infra-bootstrap; \
	fi
	@bash scripts/verify/verify_helm_template_integrity.sh
	@bash scripts/lib/ensure_cluster.sh
	@bash -euo pipefail -c '. scripts/lib/proof_prereqs.sh; export THREADFORGE_EXPECTED_ISTIO_VERSION="$(ISTIO_VERSION)"; require_supported_k8s_istio_combo_or_fail'
	@env -u SPIRE_SERVER_IMAGE -u SPIRE_AGENT_IMAGE -u ISTIO_PILOT_IMAGE \
		BOOTSTRAP_MODE="$(BOOTSTRAP_MODE)" \
		bash scripts/infra/bootstrap.sh

infra-bootstrap-runtime-image-pinning: prereq-check
	@BOOTSTRAP_MODE="$(BOOTSTRAP_MODE)" \
		bash scripts/infra/bootstrap.sh --phase runtime-image-pinning

bootstrap-verify: prereq-check
	@bash scripts/lib/ensure_cluster.sh
	@bash scripts/verify/verify_bootstrap_complete.sh
	@bash scripts/verify/verify_registry_tls_trust.sh
	@bash scripts/verify/verify_mesh_baseline.sh
	@bash scripts/verify/verify_authoritative_topology.sh

cluster-reset: prereq-check
	@if [[ "${THREADFORGE_EXECUTION_PROFILE:-local}" == "ci" ]]; then \
		bash scripts/ci/cluster_reset_wrapper.sh; \
	else \
		bash scripts/ci/reset_ci_cluster.sh; \
	fi

# Native lifecycle owner: the local kind cluster. The host registry persists.
cluster-nuke: prereq-check
	@kind delete cluster --name threadforge

native-host-contract-verify: prereq-check
	@bash scripts/infra/verify_native_host_contract.sh

ci-cluster-reset: prereq-check
	@bash scripts/ci/cluster_reset_wrapper.sh

host-trust-prime: prereq-check
	@bash scripts/infra/host_trust_prime.sh --mode prime

host-trust-verify: prereq-check
	@bash scripts/infra/host_trust_prime.sh --mode verify

###############################################################################
# PROMETHEUS CRDs (required before SPIRE install)
###############################################################################
prometheus-crds-install:
	@helm show crds prometheus-community/kube-prometheus-stack | kubectl apply --server-side -f - >/dev/null
	$(call log-ok,"Prometheus Operator CRDs applied")

###############################################################################
# KYVERNO (required before prove_system.sh)
###############################################################################
.PHONY: kyverno-install
kyverno-install:
	$(call log-step,"Installing Kyverno admission controller")
	@bash scripts/infra/ensure_kyverno_images.sh >/dev/null
	@bash scripts/infra/prepare_kyverno_release.sh >/dev/null
	@helm upgrade --install kyverno kyverno/kyverno -n kyverno \
	  --create-namespace \
	  --version 3.2.8 \
	  -f $(INFRA_DIR)/kyverno/values.yaml \
	  --no-hooks \
	  --wait --timeout=300s >/dev/null
	@for service in kyverno-svc-metrics kyverno-background-controller-metrics kyverno-cleanup-controller-metrics kyverno-reports-controller-metrics; do \
		kubectl -n kyverno patch service $$service --type=json -p='[{"op":"replace","path":"/spec/ports/0/name","value":"http-metrics"}]' >/dev/null; \
	done
	@for deployment in kyverno-admission-controller kyverno-background-controller kyverno-cleanup-controller kyverno-reports-controller; do \
		kubectl rollout status deployment/$$deployment -n kyverno --timeout=300s >/dev/null; \
	done
	$(call log-ok,"Kyverno ready")

###############################################################################
# NOTIFIER (required for prove_system.sh event delivery)
###############################################################################
.PHONY: notifier-install
notifier-install:
	$(call log-step,"Deploying threadforge-notifier")
	@$(RUN_KUBECTL) apply -f $(INFRA_DIR)/notifier/deployment.yaml >/dev/null
	@$(RUN_KUBECTL) apply -f $(INFRA_DIR)/notifier/service.yaml >/dev/null
	@$(RUN_KUBECTL) rollout status deployment/threadforge-notifier -n threadforge-system --timeout=120s >/dev/null
	$(call log-ok,"threadforge-notifier ready")

###############################################################################
# INGRESS GATEWAY (required for verify_gateway_ca_source.sh proof check)
###############################################################################
gateway-install:
	$(call log-step,"Installing istio-ingressgateway")
	@helm upgrade --install istio-ingressgateway istio-release/gateway \
	  -n istio-system --version $(ISTIO_VERSION) \
	  -f $(INFRA_DIR)/istio-ingressgateway-values.yaml >/dev/null
	@$(RUN_KUBECTL) rollout status deployment/istio-ingressgateway -n istio-system --timeout=120s >/dev/null
	$(call log-ok,"istio-ingressgateway ready")

###############################################################################
# infra-nuke (reverse order)
###############################################################################
infra-nuke: istio-nuke spire-nuke
	$(call log-ok,"Infra removed")

###############################################################################
# SPIRE
###############################################################################
# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
spire-install:
	$(call log-step,"🧬 Installing SPIRE → ns=$(SPIRE_NS)")
	@test -d $(INFRA_DIR)/spire || { echo "[FAIL] Missing chart: $(INFRA_DIR)/spire"; exit 2; }
	@set +e; ns_out="$$( $(RUN_KUBECTL) get ns $(SPIRE_NS) 2>&1 )"; ns_rc=$$?; set -e; \
	if [ $$ns_rc -ne 0 ]; then \
	  case "$$ns_out" in \
	    *"NotFound"*|*"not found"*) $(RUN_KUBECTL) create ns $(SPIRE_NS) ;; \
	    *) printf '%s\n' "$$ns_out" >&2; exit $$ns_rc ;; \
	  esac; \
	fi
	@$(RUN_HELM) upgrade --install spire $(INFRA_DIR)/spire -n $(SPIRE_NS) -f $(INFRA_DIR)/spire/values.yaml
	$(call log-step,"⏳ Waiting for SPIRE server/agent readiness…")
	@$(RUN_KUBECTL) rollout status statefulset/spire-server -n $(SPIRE_NS) --timeout=180s
	@$(RUN_KUBECTL) rollout status daemonset/spire-agent -n $(SPIRE_NS) --timeout=180s
	$(call log-ok,"SPIRE ready")

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
spire-nuke:
	$(call log-warn,"Removing SPIRE")
	$(call helm_uninstall_or_absent,spire,$(SPIRE_NS))
	@$(RUN_KUBECTL) delete ns $(SPIRE_NS) --ignore-not-found=true >/dev/null 2>&1
	$(call log-ok,"SPIRE removed (async namespace delete)")

###############################################################################
# ISTIO
###############################################################################
# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
istio-install: istio-core-install
	$(call log-step,"🕸️ Installing ThreadForge Istio policy → ns=$(ISTIO_NS)")
	@test -d $(INFRA_DIR)/istio || { echo "[FAIL] Missing chart: $(INFRA_DIR)/istio"; exit 2; }
	@set +e; ns_out="$$( $(RUN_KUBECTL) get ns $(ISTIO_NS) 2>&1 )"; ns_rc=$$?; set -e; \
	if [ $$ns_rc -ne 0 ]; then \
	  case "$$ns_out" in \
	    *"NotFound"*|*"not found"*) $(RUN_KUBECTL) create ns $(ISTIO_NS) ;; \
	    *) printf '%s\n' "$$ns_out" >&2; exit $$ns_rc ;; \
	  esac; \
	fi
	@$(RUN_HELM) upgrade --install istio $(INFRA_DIR)/istio -n $(ISTIO_NS)
	$(call log-ok,"ThreadForge Istio policy applied")

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
istio-nuke:
	$(call log-warn,"Removing Istio")
	$(call helm_uninstall_or_absent,istio,$(ISTIO_NS))
	@$(RUN_KUBECTL) delete ns $(ISTIO_NS) --ignore-not-found=true >/dev/null 2>&1
	$(call log-ok,"Istio removed (async namespace delete)")

###############################################################################
# OBSERVABILITY STACK (OPTIONAL BUT FIRST-CLASS)
###############################################################################
.PHONY: infra-observability-install infra-observability-remove

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
infra-observability-install:
	$(call log-step,Deploying ThreadForge observability with mTLS)
	@helm show crds prometheus-community/kube-prometheus-stack | kubectl apply --server-side -f - >/dev/null
	@$(RUN_KUBECTL) create namespace observability --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@$(RUN_KUBECTL) get secret grafana-admin-secret -n observability >/dev/null 2>&1 || \
	  $(RUN_KUBECTL) create secret generic grafana-admin-secret -n observability \
	    --from-literal=password=ThreadForgeAdmin2026
	@$(RUN_KUBECTL) create namespace minio --dry-run=client -o yaml | kubectl apply -f - >/dev/null; \
	  $(RUN_KUBECTL) get secret minio-secrets -n minio >/dev/null 2>&1 || \
	    $(RUN_KUBECTL) create secret generic minio-secrets -n minio \
	      --from-literal=accesskey=threadforge-minio \
	      --from-literal=secretkey=ThreadForge2026Minio
	@$(RUN_HELM) upgrade --install minio platform/deploy/infra/minio -n minio --create-namespace
	@$(RUN_HELM) upgrade --install loki platform/deploy/infra/loki -n observability --create-namespace
	@$(RUN_HELM) upgrade --install tempo platform/deploy/infra/tempo -n observability --create-namespace
	@$(RUN_HELM) upgrade --install promtail platform/deploy/infra/promtail -n observability --create-namespace
	@$(RUN_HELM) upgrade --install grafana platform/deploy/infra/grafana -n observability --create-namespace
	@$(RUN_HELM) upgrade --install prometheus platform/deploy/infra/prometheus -n observability --create-namespace
	$(call log-step,Waiting for Prometheus + Loki + Tempo + Promtail readiness)
	@$(RUN_KUBECTL) rollout status statefulset/loki -n observability --timeout=180s
	@$(RUN_KUBECTL) rollout status statefulset/tempo -n observability --timeout=180s
	@$(RUN_KUBECTL) rollout status daemonset/promtail -n observability --timeout=180s
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/observability/servicemonitors/istiod-servicemonitor.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/observability/istio-proxy-podmonitor.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/observability/threadforge-observability-rules.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/observability/forgesec-pushgateway.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/observability/observability-check-cronjob.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/observability/forgesec-continuity-check-cronjob.yaml
	$(call log-step,Removing old OpenTelemetryCollector CR)
	@$(RUN_KUBECTL) delete otelcol threadforge-collector -n observability --ignore-not-found=true 2>/dev/null
	@sleep 5
	$(call log-step,Applying mTLS-enabled Collector Deployment)
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/otel/collector-deployment.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/otel/collector-authz.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/otel/collector-destinationrule.yaml
	$(call log-step,Waiting for collector deployment readiness)
	@$(RUN_KUBECTL) rollout status deployment/threadforge-collector -n observability --timeout=180s
	@$(MAKE) observability-enforce
	$(call log-ok,"ThreadForge observability mTLS-enabled deployed")

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
infra-observability-remove:
	$(call log-warn,"Removing observability stack")
	@$(RUN_KUBECTL) delete deployment threadforge-collector -n observability --ignore-not-found=true
	@$(RUN_KUBECTL) delete service threadforge-collector -n observability --ignore-not-found=true
	@$(RUN_KUBECTL) delete configmap threadforge-collector-config -n observability --ignore-not-found=true
	@$(RUN_KUBECTL) delete sa threadforge-collector -n observability --ignore-not-found=true
	@$(RUN_KUBECTL) delete authorizationpolicy threadforge-collector -n observability --ignore-not-found=true
	@$(RUN_KUBECTL) delete peerauthentication threadforge-collector -n observability --ignore-not-found=true
	@$(RUN_KUBECTL) delete destinationrule threadforge-collector -n observability --ignore-not-found=true
	@$(RUN_KUBECTL) delete destinationrule tempo -n observability --ignore-not-found=true
	@$(RUN_KUBECTL) delete -f platform/deploy/infra/observability/forgesec-pushgateway.yaml --ignore-not-found=true
	$(call helm_uninstall_or_absent,promtail,observability)
	$(call helm_uninstall_or_absent,tempo,observability)
	$(call helm_uninstall_or_absent,loki,observability)
	$(call helm_uninstall_or_absent,grafana,observability)
	$(call helm_uninstall_or_absent,minio,minio)
	$(call log-ok,"Observability stack removed")
