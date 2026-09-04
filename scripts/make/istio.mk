###############################################################################
# ISTIO CORE (CRDs + Control Plane) — ONE TIME ONLY
###############################################################################

ISTIO_NS ?= istio-system
ISTIO_HELM_REPO ?= istio-release
THREADFORGE_REGISTRY ?= registry.threadforge.local:30500
ISTIO_PILOT_DIGEST ?= 32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f

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

.PHONY: istio-core-install istio-core-nuke

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
istio-core-install:
	$(call log-step,🧩 Installing Istio CRDs + control plane v$(ISTIO_VERSION))
	@set +e; ns_out="$$( $(RUN_KUBECTL) get ns $(ISTIO_NS) 2>&1 )"; ns_rc=$$?; set -e; \
	if [ $$ns_rc -ne 0 ]; then \
	  case "$$ns_out" in \
	    *"NotFound"*|*"not found"*) $(RUN_KUBECTL) create ns $(ISTIO_NS) ;; \
	    *) printf '%s\n' "$$ns_out" >&2; exit $$ns_rc ;; \
	  esac; \
	fi
	@if helm status istio-base -n $(ISTIO_NS) >/dev/null 2>&1 \
	    && helm status istiod -n $(ISTIO_NS) >/dev/null 2>&1 \
	    && kubectl rollout status deploy/istiod -n $(ISTIO_NS) --timeout=5s >/dev/null 2>&1; then \
		echo "✔ Istio already installed and running — skipping core install"; \
	else \
		THREADFORGE_REGISTRY=$(THREADFORGE_REGISTRY) ISTIO_TAG=$(ISTIO_VERSION) bash scripts/install/prepare_istio_images.sh && \
		helm upgrade --install istio-base $(ISTIO_HELM_REPO)/base -n $(ISTIO_NS) --version $(ISTIO_VERSION) && \
		kubectl wait --for=condition=Established \
			crd/authorizationpolicies.security.istio.io \
			crd/peerauthentications.security.istio.io \
			crd/requestauthentications.security.istio.io \
			--timeout=60s && \
		helm upgrade --install istiod $(ISTIO_HELM_REPO)/istiod -n $(ISTIO_NS) --version $(ISTIO_VERSION) \
			--set global.hub=$(THREADFORGE_REGISTRY)/istio \
			--set global.tag=$(ISTIO_VERSION) \
			--wait && \
		kubectl -n $(ISTIO_NS) set image deployment/istiod discovery=$(THREADFORGE_REGISTRY)/istio/pilot@sha256:$(ISTIO_PILOT_DIGEST) >/dev/null && \
		set +e; images_raw="$$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sed '/^$$/d')"; \
		images_rc=$$?; set -e; \
		if [ $$images_rc -ne 0 ]; then \
			printf '%s\n' "$$images_raw" >&2; \
			exit $$images_rc; \
		fi; \
		images="$$(printf '%s\n' "$$images_raw" | grep -v '^$(THREADFORGE_REGISTRY)/' || true)"; \
		if [ -n "$$images" ]; then \
			echo "$$images"; \
			echo "❌ external images detected after Istio install"; \
			exit 2; \
		fi; \
		ISTIO_NS=$(ISTIO_NS) bash scripts/install/enforce_istiod_startup_order.sh; \
	fi
	@echo "✔ Istio version installed: $(ISTIO_VERSION)"
	$(call log-ok,"Istio core ready")

istio-core-nuke:
	$(call log-warn,"Removing Istio core")
	$(call helm_uninstall_or_absent,istiod,$(ISTIO_NS))
	$(call helm_uninstall_or_absent,istio-base,$(ISTIO_NS))

###############################################################################
# ISTIO POLICY (ThreadForge Mesh Law)
###############################################################################

.PHONY: istio-policy-install istio-policy-nuke

istio-policy-install: namespaces-install
	@kubectl get crd authorizationpolicies.security.istio.io >/dev/null 2>&1 || \
			( echo "❌ Istio CRDs not present. Run istio-core-install first."; exit 2 )
	$(call log-step,"🕸️ Installing ThreadForge Istio policy")
	@set +e; apply_out="$$(kubectl apply -f platform/deploy/infra/istio/ -n $(ISTIO_NS) --ignore-not-found=false 2>&1)"; apply_rc=$$?; set -e; \
	if [ $$apply_rc -ne 0 ]; then printf '%s\n' "$$apply_out" >&2; exit $$apply_rc; fi; \
	printf '%s\n' "$$apply_out" | grep -v "unchanged" || true
	$(call log-ok,"ThreadForge Istio policy applied")

istio-policy-nuke:
	$(call log-warn,"Removing ThreadForge Istio policy")
	$(call helm_uninstall_or_absent,threadforge-istio,$(ISTIO_NS))
	$(call log-ok,"ThreadForge Istio policy removed")
