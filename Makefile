SHELL = bash
.DEFAULT_GOAL = help

SKIPERATOR_DIR := skiperator
KIND_CLUSTER_NAME ?= skiperator
KUBECTX := kind-$(KIND_CLUSTER_NAME)

.PHONY: help
help:
	@echo "k8s-research local stack"
	@echo ""
	@echo "  make cluster         create kind cluster 'kind-skiperator' + all deps (Phase 1)"
	@echo "  make run-operator    run Skiperator operator as host binary (Phase 2)"
	@echo "  make operator        start operator in background;  make operator-stop"
	@echo "  make serve-git       start git daemon for ArgoCD;    make git-stop"
	@echo "  make pf              start port-forwards (8081, 8443); make pf-stop"
	@echo "  make status          show cluster + processes + ArgoCD app state"
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

.PHONY: operator
operator:
	@test -d $(SKIPERATOR_DIR) || { echo "skiperator not cloned"; exit 1; }
	nohup $(MAKE) -C $(SKIPERATOR_DIR) run-local > /tmp/skiperator-operator.log 2>&1 &
	@echo "operator starting (log: /tmp/skiperator-operator.log)"

.PHONY: operator-stop
operator-stop:
	@pkill -f 'bin/skiperator' 2>/dev/null || true
	@pkill -f 'make run-local' 2>/dev/null || true
	@echo "operator stopped"

.PHONY: serve-git
serve-git:
	git daemon --reuseaddr --export-all --base-path=$(HOME)/src --listen=127.0.0.1 --port=9418 > /tmp/git-daemon.log 2>&1 &
	@echo "git daemon on 127.0.0.1:9418 (log: /tmp/git-daemon.log)"

.PHONY: git-stop
git-stop:
	@pkill -f 'git daemon' 2>/dev/null || true
	@echo "git daemon stopped"

.PHONY: pf
pf:
	nohup kubectl --context $(KUBECTX) port-forward -n argocd svc/argocd-server 8081:80 > /tmp/pf-argocd.log 2>&1 &
	nohup kubectl --context $(KUBECTX) port-forward -n istio-gateways svc/istio-ingress-external 8443:443 > /tmp/pf-istio.log 2>&1 &
	@echo "port-forwards: argocd UI http://127.0.0.1:8081, istio HTTPS 8443"

.PHONY: pf-stop
pf-stop:
	@pkill -f 'port-forward.*8081' 2>/dev/null || true
	@pkill -f 'port-forward.*8443' 2>/dev/null || true
	@echo "port-forwards stopped"

.PHONY: status
status:
	@echo "== cluster =="; kubectl --context $(KUBECTX) get nodes --no-headers 2>/dev/null | awk '{print $$1, $$2}' || echo "cluster not running"
	@echo "== operator =="; pgrep -f 'bin/skiperator' >/dev/null && echo "running" || echo "stopped"
	@echo "== git daemon =="; pgrep -f 'git daemon' >/dev/null && echo "running" || echo "stopped"
	@echo "== port-forwards =="; lsof -i :8081 -sTCP:LISTEN >/dev/null 2>&1 && echo "argocd 8081 up" || echo "argocd 8081 down"; lsof -i :8443 -sTCP:LISTEN >/dev/null 2>&1 && echo "istio 8443 up" || echo "istio 8443 down"
	@echo "== argo app =="; kubectl -n argocd get application k8s-apps -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}' 2>/dev/null || echo "n/a"

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
