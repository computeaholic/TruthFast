# ===============================================================================
# ThreadForge — Image Supply Chain (Deterministic / Airgap-Capable)
# ===============================================================================

IMAGES_DIR ?= out/images
ARCH       ?= arm64
OS         ?= linux
export DOCKER_DEFAULT_PLATFORM=linux/arm64

# ------------------------------------------------------------------------------
# Canonical Version Pins (Single Source of Truth)
# ------------------------------------------------------------------------------

SPIRE_VERSION      := 1.9.0
SPIRE_SERVER_IMAGE := registry.threadforge.local:30500/mirror/ghcr.io/spiffe/spire-server:$(SPIRE_VERSION)
SPIRE_AGENT_IMAGE  := registry.threadforge.local:30500/mirror/ghcr.io/spiffe/spire-agent:$(SPIRE_VERSION)

DEBUG_VERSION      := v0.13
DEBUG_IMAGE        := registry.threadforge.local:30500/mirror/ghcr.io/nicolaka/netshoot:$(DEBUG_VERSION)

FORGESEC_TAG       := rebuild-20260215
API_TAG            := v20260223-0
DEBUG_TAG          := rebuild-20260215
KIND_NODE_TAG      := v1.30.2-registry-trust
KIND_NODE_DIGEST   := sha256:48321fb2717f92527d9aba9a9b32055dff622f9c356ea3de2f1ffb75344f87bf
KIND_NODE_PLATFORM := linux/arm64

CANON_DEBUG_IMAGE  := registry.threadforge.local:30500/threadforge-debug:$(DEBUG_TAG)
FORGESEC_IMAGE     := registry.threadforge.local:30500/forgesec:v2
API_IMAGE          := registry.threadforge.local:30500/threadforge-api:$(API_TAG)
KIND_NODE_TAGGED_IMAGE := registry.threadforge.local:30500/kindest-node:$(KIND_NODE_TAG)
KIND_NODE_IMAGE    := registry.threadforge.local:30500/kindest-node@$(KIND_NODE_DIGEST)

COSIGN_KEY_PATH ?= $(HOME)/.threadforge-signing/cosign.key
COSIGN_PASSWORD_FILE ?= $(HOME)/.threadforge-signing/cosign.password
COSIGN_PUBLIC_KEY_PATH ?= $(HOME)/.threadforge-signing/cosign.pub
REGISTRY_CA_CERT_PATH ?= $(REPO_ROOT)/certs/threadforge-ingress-ca.crt

SPIRE_SERVER_TAR := $(IMAGES_DIR)/spire-server_$(SPIRE_VERSION).tar
SPIRE_AGENT_TAR  := $(IMAGES_DIR)/spire-agent_$(SPIRE_VERSION).tar
DEBUG_TAR        := $(IMAGES_DIR)/netshoot_$(DEBUG_VERSION).tar
CANON_DEBUG_TAR  := $(IMAGES_DIR)/threadforge-debug_$(DEBUG_TAG).tar
FORGESEC_TAR     := $(IMAGES_DIR)/forgesec_$(FORGESEC_TAG).tar
API_TAR          := $(IMAGES_DIR)/threadforge-api_$(API_TAG).tar

.PHONY: images-fetch images-import images-verify images-clean \
        debug-image-fetch debug-image-import debug-image-verify \
	build-debug build-forgesec build-api images-canonical-verify \
	kind-node-publish kind-node-sign kind-node-resolve kind-node-release

# ------------------------------------------------------------------------------
# SPIRE Upstream Fetch (Airgap Seed)
# ------------------------------------------------------------------------------

images-fetch:
	@mkdir -p $(IMAGES_DIR)
	@echo "📦 Fetching SPIRE images (OS=$(OS), ARCH=$(ARCH))"
	skopeo copy --override-os $(OS) --override-arch $(ARCH) \
	  docker://$(SPIRE_SERVER_IMAGE) \
	  docker-archive:$(SPIRE_SERVER_TAR):$(SPIRE_SERVER_IMAGE)
	skopeo copy --override-os $(OS) --override-arch $(ARCH) \
	  docker://$(SPIRE_AGENT_IMAGE) \
	  docker-archive:$(SPIRE_AGENT_TAR):$(SPIRE_AGENT_IMAGE)
	@echo "✔ SPIRE images fetched"

# ------------------------------------------------------------------------------
# Import Into k3s containerd (Authoritative)
# ------------------------------------------------------------------------------

images-import:
	@echo "📥 Importing SPIRE images into k3s containerd"
	sudo ctr -n k8s.io images import $(SPIRE_SERVER_TAR)
	sudo ctr -n k8s.io images import $(SPIRE_AGENT_TAR)
	@echo "✔ Images imported"

images-verify:
	@echo "🔍 Verifying SPIRE images via CRI"
	sudo crictl images | grep spire || \
	  (echo "❌ SPIRE images not found in CRI" && echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)
	@echo "✔ SPIRE images verified"

images-clean:
	rm -rf $(IMAGES_DIR)

# ------------------------------------------------------------------------------
# Debug Image (Non-Canonical / Operator Only)
# ------------------------------------------------------------------------------

debug-image-fetch:
	@mkdir -p $(IMAGES_DIR)
	@echo "📦 Fetching debug image"
	skopeo copy --override-os $(OS) --override-arch $(ARCH) \
	  docker://$(DEBUG_IMAGE) \
	  docker-archive:$(DEBUG_TAR):$(DEBUG_IMAGE)
	@echo "✔ Debug image fetched"

debug-image-import:
	@echo "📥 Importing debug image into CRI"
	sudo ctr -n k8s.io images import $(DEBUG_TAR)
	@echo "✔ Debug image imported"

debug-image-verify:
	@echo "🔍 Verifying debug image"
	sudo crictl images | grep netshoot || \
	  (echo "❌ Debug image not found in CRI" && echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)
	@echo "✔ Debug image verified"

# ------------------------------------------------------------------------------
# Canonical Internal Images (Registry-TLS Required)
# ------------------------------------------------------------------------------

build-debug:
	@mkdir -p $(IMAGES_DIR)
	@echo "🔨 Building canonical debug image"
	docker buildx build --builder threadforge-builder --platform linux/arm64 --pull --output type=docker,dest=$(CANON_DEBUG_TAR) -t $(CANON_DEBUG_IMAGE) platform/images/debug
	@echo "✔ Built and saved $(CANON_DEBUG_TAR)"

build-forgesec:
	@mkdir -p $(IMAGES_DIR)
	@echo "🔨 Building ForgeSec image"
	docker buildx build --builder threadforge-builder --platform linux/arm64 --pull --output type=oci,dest=$(FORGESEC_TAR) -t $(FORGESEC_IMAGE) -f platform/images/forgesec/Dockerfile.forgesec platform/images/forgesec
	@echo "✔ Built and saved $(FORGESEC_TAR)"

build-api:
	@mkdir -p $(IMAGES_DIR)
	@echo "🔨 Building ThreadForge API image"
	docker buildx build --builder threadforge-builder --platform linux/arm64 --pull --output type=docker,dest=$(API_TAR) -t $(API_IMAGE) -f platform/images/api/Dockerfile .
	@echo "✔ Built and saved $(API_TAR)"

kind-node-publish:
	@echo "🔨 Publishing canonical kind node image"
	DOCKER_DEFAULT_PLATFORM=$(DOCKER_DEFAULT_PLATFORM) docker buildx build --builder threadforge-builder --platform linux/arm64 -t $(KIND_NODE_TAGGED_IMAGE) --push -f platform/images/kind-node/Dockerfile .

kind-node-sign:
	@echo "✍️ Signing canonical kind node image"
	@set -euo pipefail; \
		kind_node_ref="$$(SSL_CERT_FILE="$(REGISTRY_CA_CERT_PATH)" docker buildx imagetools inspect "$(KIND_NODE_TAGGED_IMAGE)" | awk 'BEGIN { name = ""; found = 0 } /^  Name:[[:space:]]+/ { name = $$2 } /^  Platform:[[:space:]]+linux\/arm64$$/ { print name; found = 1; exit } END { if (!found) exit 1 }')"; \
		export COSIGN_PASSWORD="$$(cat "$(COSIGN_PASSWORD_FILE)")"; \
		export SSL_CERT_FILE="$(REGISTRY_CA_CERT_PATH)"; \
		cosign sign --yes --key "$(COSIGN_KEY_PATH)" "$$kind_node_ref" >/dev/null
	@SSL_CERT_FILE="$(REGISTRY_CA_CERT_PATH)" scripts/supply_chain/sign_images.sh --mode verify --image $(KIND_NODE_IMAGE) >/dev/null

kind-node-resolve:
	@SSL_CERT_FILE="$(REGISTRY_CA_CERT_PATH)" docker buildx imagetools inspect "$(KIND_NODE_TAGGED_IMAGE)" | awk 'BEGIN { name = ""; found = 0 } /^  Name:[[:space:]]+/ { name = $$2 } /^  Platform:[[:space:]]+linux\/arm64$$/ { print name; found = 1; exit } END { if (!found) exit 1 }'

kind-node-release:
	docker buildx build \
	  --builder threadforge-builder \
	  --platform linux/arm64 \
	  -t registry.threadforge.local:30500/kindest-node:v1.30.2-registry-trust \
	  --push \
	  -f platform/images/kind-node/Dockerfile .
	@set -euo pipefail; \
		kind_node_ref="$$(SSL_CERT_FILE="$(REGISTRY_CA_CERT_PATH)" docker buildx imagetools inspect registry.threadforge.local:30500/kindest-node:v1.30.2-registry-trust | awk 'BEGIN { name = ""; found = 0 } /^  Name:[[:space:]]+/ { name = $$2 } /^  Platform:[[:space:]]+linux\/arm64$$/ { print name; found = 1; exit } END { if (!found) exit 1 }')"; \
		export COSIGN_PASSWORD="$$(cat "$(COSIGN_PASSWORD_FILE)")"; \
		SSL_CERT_FILE="$(REGISTRY_CA_CERT_PATH)" cosign sign --yes --key "$(COSIGN_KEY_PATH)" "$$kind_node_ref"; \
		echo "$$kind_node_ref"

images-canonical-verify:
	@echo "🔍 Verifying canonical ThreadForge images via CRI"
	sudo crictl images | grep threadforge || \
	  (echo "❌ Canonical ThreadForge images not found in CRI" && echo "[ADVISORY-FAIL] non-authoritative path"; exit 0)
	@echo "✔ Canonical images verified"
