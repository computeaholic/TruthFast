###############################################################################
# THREADFORGE — K3S MODULE (V13)
# Purpose: non-native operator utilities for a separately managed k3s VM.
# These targets are intentionally excluded from bootstrap, reset, rebuild,
# nuke, Golden Boot, and authoritative validation.
###############################################################################

.PHONY: k3-install k3-reset k3-wipe k3-health

K3S_VERSION ?= v1.30.5+k3s1
K3S_INSTALL_SCRIPT ?= https://get.k3s.io
K3S_DISABLE ?= traefik,servicelb

###############################################################################
# k3-install
# Single canonical path: install k3s on the managed VM over SSH.
###############################################################################
# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
k3-install: vm-preflight
	$(call log-step,"🐄 Installing k3s ($(K3S_VERSION)) on VM")
	@$(SSH) 'curl -sfL $(K3S_INSTALL_SCRIPT) | INSTALL_K3S_VERSION="$(K3S_VERSION)" INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --disable=$(K3S_DISABLE)" sh -'
	$(call log-ok,"k3s installed")

###############################################################################
# k3-reset
###############################################################################
# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
k3-reset: vm-preflight
	$(call log-warn,"Resetting k3s service on VM")
	@$(SSH) '$(SUDO) systemctl restart k3s'
	$(call log-ok,"k3s restarted")

###############################################################################
# k3-wipe
###############################################################################
# OPERATOR_MUTATION_TARGET
# Requires manual execution by trusted operator.
k3-wipe: vm-preflight
	$(call log-warn,"Wiping k3s on VM")
	@$(SSH) 'if [ -x /usr/local/bin/k3s-uninstall.sh ]; then $(SUDO) /usr/local/bin/k3s-uninstall.sh; else echo "[INFO] k3s already absent; skipping uninstall"; fi'
	$(call log-ok,"k3s removed")

###############################################################################
# k3-health
###############################################################################
k3-health: core-verify-bins kubeconfig-sync
	$(call log-step,"�� Checking node + core pods")
	@$(RUN_KUBECTL) get nodes -o wide
	@$(RUN_KUBECTL) get pods -n kube-system
	$(call log-ok,"k3 health check complete")
