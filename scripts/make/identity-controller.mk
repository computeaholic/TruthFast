IDENTITY_CONTROLLER_DIR := internal/control/identity/identity-controller
CONTROLLER_GEN := bin/controller-gen

.PHONY: identity-controller-generate
identity-controller-generate:
	cd $(IDENTITY_CONTROLLER_DIR) && \
	GOBIN=$$(pwd)/bin \
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.20.0 && \
	$(CONTROLLER_GEN) \
	  object:headerFile=hack/boilerplate.go.txt \
	  paths=./api/...

.PHONY: identity-controller-manifests
identity-controller-manifests:
	cd $(IDENTITY_CONTROLLER_DIR) && \
	$(CONTROLLER_GEN) \
	  crd \
	  paths=./api/... \
	  output:crd:dir=./config/crd/bases
