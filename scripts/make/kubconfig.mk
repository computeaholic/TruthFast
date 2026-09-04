###############################################################################
# THREADFORGE — KUBECONFIG SYNC MODULE (V13)
# Purpose:
#   Pull → rewrite → activate kubeconfig from the managed VM for local use.
#
# Single canonical path; no execution modes.
###############################################################################

# Requires: core.mk variables + SSH_* vars defined in umbrella Makefile

REMOTE_K3S_KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml
LOCAL_CONFIG ?= $(KUBECONFIG_DIR)/threadforge.yaml

.PHONY: kubeconfig-sync kubeconfig-print kubeconfig-reset kubeconfig-verify kubeconfig-contexts

###############################################################################
# kubeconfig-sync
###############################################################################
kubeconfig-sync:
	$(call log-step,"📥 Pulling kubeconfig from VM → $(LOCAL_CONFIG)")
	mkdir -p $(STATE_DIR)/kube
	@if [ -f "$(REMOTE_K3S_KUBECONFIG)" ]; then \
	  echo "[TF] 📥 Using local k3s kubeconfig: $(REMOTE_K3S_KUBECONFIG)"; \
	  $(SUDO) cat "$(REMOTE_K3S_KUBECONFIG)" > $(STATE_DIR)/kube/threadforge.yaml.tmp; \
	  cp $(STATE_DIR)/kube/threadforge.yaml.tmp $(LOCAL_CONFIG); \
	  rm -f $(STATE_DIR)/kube/threadforge.yaml.tmp; \
	else \
	  scp -q $(SSH_OPTS) \
	    $(SSH_USER)@$(SSH_HOST):/etc/rancher/k3s/k3s.yaml \
	    $(STATE_DIR)/kube/threadforge.yaml.tmp; \
	  sed -E 's#server: https://127\\.0\\.0\\.1:6443#server: https://$(SSH_HOST):6443#g' \
	    $(STATE_DIR)/kube/threadforge.yaml.tmp > $(LOCAL_CONFIG); \
	  rm -f $(STATE_DIR)/kube/threadforge.yaml.tmp; \
	fi
	$(call log-ok,"kubeconfig ready")

###############################################################################
kubeconfig-reset:
	$(call log-warn,"Resetting local kubeconfig cache")
	@rm -f $(LOCAL_CONFIG)
	$(call log-ok,"Removed $(LOCAL_CONFIG)")

###############################################################################
kubeconfig-print:
	$(call log-step,"📄 Kubeconfig: $(LOCAL_CONFIG)")
	@ls -lah $(LOCAL_CONFIG) || true
	@echo "▶ SHA256:"; (shasum -a 256 $(LOCAL_CONFIG) || true)

###############################################################################
kubeconfig-verify:
	$(call log-step,"🧪 Verifying cluster API reachability…")
	@$(RUN_KUBECTL) get --raw=/healthz >/dev/null
	$(call log-ok,"API server reachable")

###############################################################################
kubeconfig-contexts:
	$(call log-step,"📚 kubeconfig contexts")
	@$(RUN_KUBECTL) config get-contexts
