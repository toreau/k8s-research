SHELL = bash
.DEFAULT_GOAL = help

SKIPERATOR_DIR := skiperator
KIND_CLUSTER_NAME ?= skiperator

.PHONY: help
help:
	@echo "k8s-research local stack"
	@echo ""
	@echo "  make cluster         create kind cluster 'kind-skiperator' + all deps (Phase 1)"
	@echo "  make run-operator    run Skiperator operator as host binary (Phase 2)"
	@echo "  make cluster-delete  delete the kind cluster"
	@echo "  make verify          print tool versions"

.PHONY: cluster
cluster:
	@test -d $(SKIPERATOR_DIR) || { echo "clone first: git clone https://github.com/kartverket/skiperator.git $(SKIPERATOR_DIR)"; exit 1; }
	$(MAKE) -C $(SKIPERATOR_DIR) setup-local

.PHONY: run-operator
run-operator:
	@test -d $(SKIPERATOR_DIR) || { echo "skiperator not cloned"; exit 1; }
	$(MAKE) -C $(SKIPERATOR_DIR) run-local

.PHONY: cluster-delete
cluster-delete:
	kind delete cluster --name $(KIND_CLUSTER_NAME)

.PHONY: verify
verify:
	@echo "kind:   $$(kind version | head -1)"
	@echo "helm:   $$(helm version --short)"
	@echo "argocd: $$(argocd version --client | head -1)"
	@echo "docker: $$(docker info --format '{{.OperatingSystem}} {{.Architecture}} {{.NCPU}} CPUs / {{.MemTotal}}')"
	@echo "kubectl:$$(kubectl version --client | head -1)"
