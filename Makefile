
# Image URL to use all building/pushing image targets
IMG ?= controller:latest
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.29.0

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
# Be aware that the target commands are only tested with Docker which is
# scaffolded by default. However, you might want to replace it to use other
# tools. (i.e. podman)
CONTAINER_TOOL ?= docker

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk command is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role paths="./..." output:stdout

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" go test $$(go list ./... | grep -v /e2e) -v -ginkgo.v -coverprofile cover.out

# Utilize Kind or modify the e2e tests to load the image locally, enabling compatibility with other vendors.
.PHONY: test-e2e  # Run the e2e tests against a Kind k8s instance that is spun up.
test-e2e:
	go test ./test/e2e/ -v -ginkgo.v

.PHONY: lint
lint: golangci-lint ## Run golangci-lint linter & yamllint
	$(GOLANGCI_LINT) run

.PHONY: lint-fix
lint-fix: golangci-lint ## Run golangci-lint linter and perform fixes
	$(GOLANGCI_LINT) run --fix

##@ Build

.PHONY: build
build: manifests generate fmt vet ## Build manager binary.
	go build -o bin/manager cmd/main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

# If you wish to build the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	$(CONTAINER_TOOL) build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${IMG}

# PLATFORMS defines the target platforms for the manager image be built to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - be able to use docker buildx. More info: https://docs.docker.com/build/buildx/
# - have enabled BuildKit. More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image to your registry (i.e. if you do not set a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To adequately provide solutions that are compatible with multiple platforms, you should consider using this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- $(CONTAINER_TOOL) buildx create --name project-v3-builder
	$(CONTAINER_TOOL) buildx use project-v3-builder
	- $(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross .
	- $(CONTAINER_TOOL) buildx rm project-v3-builder
	rm Dockerfile.cross

.PHONY: build-installer
build-installer: manifests generate kustomize ## Generate a consolidated YAML with CRDs and deployment.
	mkdir -p dist
	@if [ -d "config/crd" ]; then \
		$(KUSTOMIZE) build config/crd > dist/install.yaml; \
	fi
	echo "---" >> dist/install.yaml  # Add a document separator before appending
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default >> dist/install.yaml

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | $(KUBECTL) apply -f -

.PHONY: undeploy
undeploy: kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

##@ Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUBECTL ?= kubectl
KUSTOMIZE ?= $(LOCALBIN)/kustomize-$(KUSTOMIZE_VERSION)
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen-$(CONTROLLER_TOOLS_VERSION)
ENVTEST ?= $(LOCALBIN)/setup-envtest-$(ENVTEST_VERSION)
GOLANGCI_LINT = $(LOCALBIN)/golangci-lint-$(GOLANGCI_LINT_VERSION)

## Tool Versions
KUSTOMIZE_VERSION ?= v5.3.0
CONTROLLER_TOOLS_VERSION ?= v0.14.0
ENVTEST_VERSION ?= v0.0.0-20240215143116-d0396a3d6f9f
GOLANGCI_LINT_VERSION ?= v1.54.2

.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v5,$(KUSTOMIZE_VERSION))

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_TOOLS_VERSION))

.PHONY: envtest
envtest: $(ENVTEST) ## Download setup-envtest locally if necessary.
$(ENVTEST): $(LOCALBIN)
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(ENVTEST_VERSION))

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## Download golangci-lint locally if necessary.
$(GOLANGCI_LINT): $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/cmd/golangci-lint,${GOLANGCI_LINT_VERSION})

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary (ideally with version)
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f $(1) ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv "$$(echo "$(1)" | sed "s/-$(3)$$//")" $(1) ;\
}
endef

##@ Kind
.PHONY: kind kind-up deploy-argocd deploy-namespace-generator register-remote1 apply-argocd-app port-forward clean down

K8S_LOCAL_CLUSTER_NAME := argocd-playground
K8S_REMOTE_CLUSTER_NAME := remote1
ARGOCD_NAMESPACE := argocd
KUBE_CONTEXT := kind-$(K8S_LOCAL_CLUSTER_NAME)
KUBECTL := kubectl --context=$(KUBE_CONTEXT) -n $(ARGOCD_NAMESPACE)

kind: $(KIND_CONFIG) kind-up deploy-argocd deploy-namespace-generator apply-argocd-app port-forward

kind-up:
	kind get clusters | grep ${K8S_LOCAL_CLUSTER_NAME} || kind create cluster --name ${K8S_LOCAL_CLUSTER_NAME} --config ./hack/kind/local.yaml
	kind get clusters | grep ${K8S_REMOTE_CLUSTER_NAME} || kind create cluster --name ${K8S_REMOTE_CLUSTER_NAME} --config ./hack/kind/remote.yaml

deploy-argocd:
	@echo "Deploying ArgoCD to the Kind cluster..."
	@kubectl --context $(KUBE_CONTEXT) create namespace argocd 2>/dev/null || true
	$(KUBECTL) apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	@echo "Waiting for Argo CD server deployment to be available..."
	$(KUBECTL) wait --for=condition=available --timeout=600s deployment/argocd-server

deploy-namespace-generator:
	@echo "Deploying Namespace Generator to the Kind cluster..."
	$(KUBECTL) apply -k manifests
	$(KUBECTL) wait --for=condition=available --timeout=600s deployment/namespace-generator

REMOTE1_CLUSTER_NAME := kind-remote1
REMOTE1_SERVER ?= $(shell kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="$(REMOTE1_CLUSTER_NAME)")].cluster.server}')
REMOTE1_CA_DATA ?= $(shell kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="$(REMOTE1_CLUSTER_NAME)")].cluster.certificate-authority-data}')

register-remote1:
	@echo "Registering remote cluster 'remote1' in the argocd namespace on cluster $(ARGOCD_CONTEXT)..."
	@echo "Using server: $(REMOTE1_SERVER)"
	$(KUBECTL) create secret generic remote1 \
  	  --from-literal=name=remote1 \
  	  --from-literal=server="$(REMOTE1_SERVER)" \
  	  --from-literal=config='{"tlsClientConfig": {"insecure": false, "caData": "$(REMOTE1_CA_DATA)"}}'

apply-argocd-app:
	@echo "Applying ArgoCD application..."
	$(KUBECTL) apply -f example/appset.yaml

port-forward:
	@echo "Login credentials:"
	@echo "Username: admin"
	@echo "Password: $(shell kubectl --context $(KUBE_CONTEXT) -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
	@echo "Port forwarding ArgoCD server. Access the UI at http://localhost:8080"
	@if [ -f .argocd-pf.pid ]; then \
	  PID=$$(cat .argocd-pf.pid); \
	  if kill -0 $$PID 2>/dev/null; then \
		echo "Port-forward already running with PID $$PID. Skipping..."; \
		exit 0; \
	  else \
		echo "Stale PID file found. Removing..."; \
		rm -f .argocd-pf.pid; \
	  fi; \
	fi
	@echo "Starting port-forward for ArgoCD server on http://localhost:8080..."
	@kubectl --context $(KUBE_CONTEXT) port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 & echo $$! > .argocd-pf.pid

clean:
	@if [ -f .argocd-pf.pid ]; then \
	  echo "Killing port-forward process with PID $$(cat .argocd-pf.pid)..."; \
	  kill $$(cat .argocd-pf.pid) && rm -f .argocd-pf.pid; \
	else \
	  echo "No port-forward process found."; \
	fi

down:
	kind delete clusters ${K8S_LOCAL_CLUSTER_NAME}
	kind delete clusters ${K8S_REMOTE_CLUSTER_NAME}

reset:
	kubectl --context platform -n argocd delete -k manifests/ || true
	sleep 3
	kubectl --context platform -n argocd apply -k manifests/
	kubectl --context platform -n argocd wait --for=condition=available --timeout=600s deployment/namespace-generator
	kubectl --context platform -n argocd logs -f deploy/namespace-generator

logs:
	kubectl --context platform -n argocd logs -f deploy/namespace-generator