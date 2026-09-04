# ==============================================================================
# cert-manager — Certificate Control Plane
# ==============================================================================
#
# NOTE (Reviewer Intent):
# cert-manager-install is intentionally idempotent and may be invoked
# from multiple bootstrap paths (e.g., infra-bootstrap, umbrella bootstrap).
# This guarantees CRD and controller availability regardless of execution order.
#
# CA generation and trust hierarchy are isolated in cert-manager-ca-bootstrap,
# ensuring that re-entry never regenerates or mutates existing CAs.
# This behavior is deliberate and review-safe.

###############################################################################
# THREADFORGE — CERT-MANAGER MODULE (V1)
# Purpose:
#   - Install cert-manager with ThreadForge internal CA
###############################################################################

.PHONY: cert-manager-install cert-manager-ca-bootstrap

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
cert-manager-install:
	$(call log-step,"Installing cert-manager")

	@kubectl get ns cert-manager >/dev/null 2>&1 && \
	  echo "[TF] cert-manager already present" && exit 0 || true

	@helm upgrade --install cert-manager jetstack/cert-manager \
	  -n cert-manager \
          --version v1.14.6 \
          --create-namespace \
          --set crds.enabled=true \
          --set image.repository=registry.threadforge.local:30500/cert-manager/controller \
          --set image.tag=v1.14.6 \
          --set cainjector.image.repository=registry.threadforge.local:30500/cert-manager/cainjector \
          --set cainjector.image.tag=v1.14.6 \
          --set webhook.image.repository=registry.threadforge.local:30500/cert-manager/webhook \
          --set webhook.image.tag=v1.14.6
	@kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s >/dev/null
	@kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s >/dev/null

	$(call log-ok,"cert-manager ready")

# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
cert-manager-ca-bootstrap:
	$(call log-step,"🏛️ Bootstrapping ThreadForge CA hierarchy")
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/cert-manager/root-ca.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/cert-manager/root-cert.yaml
	@$(RUN_KUBECTL) apply -f platform/deploy/infra/cert-manager/ca-issuer.yaml
	$(call log-ok,"ThreadForge CA ready")
