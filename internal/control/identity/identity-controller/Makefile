CONTROLLER_GEN := bin/controller-gen

.PHONY: identity-controller-generate
identity-controller-generate:
	GOBIN=$$(pwd)/bin \
	go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.20.0 && \
	$(CONTROLLER_GEN) \
	  object:headerFile=hack/boilerplate.go.txt \
	  paths=./api/...

.PHONY: identity-controller-manifests
identity-controller-manifests:
	$(CONTROLLER_GEN) \
	  crd \
	  paths=./api/... \
	  output:crd:dir=./config/crd/bases