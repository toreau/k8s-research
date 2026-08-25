SHELL = bash
.DEFAULT_GOAL = help

SKIPERATOR_DIR := skiperator
KIND_CLUSTER_NAME ?= skiperator
KUBECTX := kind-$(KIND_CLUSTER_NAME)
ASTRONOMY_DIR := $(HOME)/src/astronomy.aursand.no
ASTRONOMY_IMAGE ?= ghcr.io/toreau/astronomy-api
TESTAPP_IMAGE ?= ghcr.io/toreau/k8s-testapp
GHCR_USER ?= toreau
ASTRONOMY_ENV := .env.astronomy
ASTRONOMY_HOST := astronomy.172.21.255.200.nip.io

.PHONY: help
help:
	@echo "k8s-research local stack"
	@echo ""
	@echo "  make cluster         create kind cluster 'kind-skiperator' + all deps (Phase 1)"
	@echo "  make run-operator    run Skiperator operator as host binary (Phase 2)"
	@echo "  make operator        start operator in background;  make operator-stop"
	@echo "  make pf              start port-forwards (8081, 8443); make pf-stop"
	@echo "  make status          show cluster + processes + all ArgoCD apps"
	@echo "  make argo-sync       sync all ArgoCD apps (parent + 6 apps, in order)"
	@echo "  make cluster-delete  delete the kind cluster"
	@echo "  make verify          print tool versions"
	@echo "  make astronomy-image build+push arm64, merge multi-arch (CI pushes amd64) to GHCR"
	@echo "  make testapp-image   build+push UID-150 testapp image to GHCR"
	@echo "  make astronomy       bootstrap the astronomy demo (secrets/sync/ingest/cert/verify)"
	@echo "  make astronomy-secrets  ensure astronomy-db-creds secrets (from .env.astronomy)"
	@echo "  make astronomy-cert     copy the app TLS secret from istio-gateways into astronomy"
	@echo "  make astronomy-verify   smoke-test the astronomy demo (fail-fast)"
	@echo "  make observability   bootstrap Prometheus+Grafana (exclusions, sync, pf-grafana)"
	@echo "  make pf-grafana      port-forwards: Grafana 3000, Prometheus 9090"
	@echo "  make astronomy-auto-update       run the auto-update watcher once (foreground)"
	@echo "  make astronomy-auto-update-loop  start watcher in background;   astronomy-auto-update-stop"
	@echo "  make astronomy-auto-update-plist install launchd agent (auto-start at login)"

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

.PHONY: pf
pf:
	nohup kubectl --context $(KUBECTX) port-forward -n argocd svc/argocd-server 8081:80 > /tmp/pf-argocd.log 2>&1 &
	nohup kubectl --context $(KUBECTX) port-forward -n istio-gateways svc/istio-ingress-external 8443:443 > /tmp/pf-istio.log 2>&1 &
	@echo "port-forwards: argocd UI http://127.0.0.1:8081, istio HTTPS 8443"

.PHONY: pf-stop
pf-stop:
	@pkill -f 'port-forward.*8081' 2>/dev/null || true
	@pkill -f 'port-forward.*8443' 2>/dev/null || true
	@pkill -f 'port-forward.*3000' 2>/dev/null || true
	@pkill -f 'port-forward.*9090' 2>/dev/null || true
	@echo "port-forwards stopped"

.PHONY: pf-grafana
pf-grafana:
	nohup kubectl --context $(KUBECTX) port-forward -n monitoring svc/grafana 3000:3000 > /tmp/pf-grafana.log 2>&1 &
	nohup kubectl --context $(KUBECTX) port-forward -n monitoring svc/prometheus-operated 9090:9090 > /tmp/pf-prom.log 2>&1 &
	@echo "grafana http://127.0.0.1:3000 (admin/admin), prometheus http://127.0.0.1:9090"

# Bootstrap Prometheus+Grafana (Fase 3): ensure 'monitoring' is exempt from
# Skiperator default-deny, sync, wait for operator/Prometheus/Grafana, port-forwards.
# NB: the prometheus-operator Deployment/SA live in the 'default' namespace (manifest).
.PHONY: observability
observability:
	@echo "== observability bootstrap =="
	@kubectl --context $(KUBECTX) get nodes >/dev/null 2>&1 || { echo "cluster not running — run: make cluster"; exit 1; }
	@kubectl --context $(KUBECTX) -n skiperator-system patch cm namespace-exclusions --type merge -p '{"data":{"monitoring":"true"}}' >/dev/null 2>&1 || true
	@$(MAKE) argo-sync >/dev/null 2>&1 || true
	@kubectl --context $(KUBECTX) -n default rollout status deploy/prometheus-operator --timeout=120s >/dev/null 2>&1 || { echo "prometheus-operator not ready"; exit 1; }
	@kubectl --context $(KUBECTX) -n monitoring wait --for=condition=Available prometheus/prometheus-k8s --timeout=180s >/dev/null 2>&1 || echo "warn: Prometheus not Available yet (targets will appear shortly)"
	@kubectl --context $(KUBECTX) -n monitoring rollout status deploy/grafana --timeout=120s >/dev/null 2>&1 || { echo "grafana not ready"; exit 1; }
	@$(MAKE) pf-grafana
	@echo "== observability: grafana http://127.0.0.1:3000 (admin/admin) · prometheus http://127.0.0.1:9090 =="

# Sync all ArgoCD apps: parent first, then the 6 apps in dependency order
# (astronomy; observability-base before prometheus-platform so the monitoring
# namespace exists; then grafana; cert-sync/sample-apps independent). Apps are
# automated, so this is mostly a fast confirmation + apply of new commits.
ARGO_APPS := astronomy observability-base prometheus-platform grafana cert-sync sample-apps

.PHONY: argo-sync
argo-sync:
	@echo "== argo sync =="
	@argocd app sync k8s-apps >/dev/null 2>&1 || true
	@for app in $(ARGO_APPS); do \
		echo "  syncing $$app"; \
		argocd app sync $$app >/dev/null 2>&1 || { echo "  $$app: FAIL"; exit 1; }; \
	done
	@echo "argo-sync: all 6 apps synced"

.PHONY: status
status:
	@echo "== cluster =="; kubectl --context $(KUBECTX) get nodes --no-headers 2>/dev/null | awk '{print $$1, $$2}' || echo "cluster not running"
	@echo "== operator =="; pgrep -f 'bin/skiperator' >/dev/null && echo "running" || echo "stopped"
	@echo "== watcher =="; pgrep -f 'astronomy-auto-update.sh' >/dev/null && echo "running" || echo "stopped"
	@echo "== port-forwards =="; lsof -i :8081 -sTCP:LISTEN >/dev/null 2>&1 && echo "argocd 8081 up" || echo "argocd 8081 down"; lsof -i :8443 -sTCP:LISTEN >/dev/null 2>&1 && echo "istio 8443 up" || echo "istio 8443 down"
	@echo "== argo apps =="; kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null || echo "n/a"

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

.PHONY: ghcr-login
ghcr-login:
	@gh auth token | docker login ghcr.io -u $(GHCR_USER) --password-stdin

# Build+push the astronomy-api arm64 image locally (CI pushes amd64) and merge
# both into the multi-arch :latest / :main-<sha> manifests on GHCR.
.PHONY: astronomy-image
astronomy-image:
	@test -d $(ASTRONOMY_DIR) || { echo "clone first: gh repo clone toreau/astronomy.aursand.no $(ASTRONOMY_DIR)"; exit 1; }
	@test "$$(git -C $(ASTRONOMY_DIR) rev-parse HEAD)" = "$$(git ls-remote https://github.com/toreau/astronomy.aursand.no.git main | cut -f1)" || { echo "local astronomy HEAD != origin/main; git pull in $(ASTRONOMY_DIR) first"; exit 1; }
	$(MAKE) ghcr-login
	@docker buildx create --name multi --driver docker-container --use >/dev/null 2>&1 || true
	@SHA=$$(git -C $(ASTRONOMY_DIR) rev-parse HEAD); \
	echo "building arm64 (SHA=$$SHA)..."; \
	docker buildx build --platform linux/arm64 --push \
		-t $(ASTRONOMY_IMAGE):arm64-$$SHA \
		-f $(ASTRONOMY_DIR)/src/Astronomy.Api/Dockerfile $(ASTRONOMY_DIR); \
	echo "merging multi-arch manifest (amd64 from CI + arm64 local)..."; \
	docker buildx imagetools create \
		-t $(ASTRONOMY_IMAGE):latest \
		-t $(ASTRONOMY_IMAGE):main-$$SHA \
		$(ASTRONOMY_IMAGE):main-$$SHA \
		$(ASTRONOMY_IMAGE):arm64-$$SHA

# Astronomy auto-update watcher (scripts/astronomy-auto-update.sh): polls the
# astronomy repo's main; on a new commit builds arm64 + merges the multi-arch
# manifest, bumps the digest in apps/astronomy, commits and syncs ArgoCD.
.PHONY: astronomy-auto-update astronomy-auto-update-loop astronomy-auto-update-stop astronomy-auto-update-plist
astronomy-auto-update:
	bash scripts/astronomy-auto-update.sh --once
astronomy-auto-update-loop:
	nohup bash scripts/astronomy-auto-update.sh --loop > /tmp/astronomy-auto-update.stdout 2>&1 &
	@echo "watcher started (log: /tmp/astronomy-auto-update.log; stop: make astronomy-auto-update-stop)"
astronomy-auto-update-stop:
	@pkill -f 'astronomy-auto-update.sh' 2>/dev/null || true
	@echo "watcher stopped"
astronomy-auto-update-plist:
	@mkdir -p $(HOME)/Library/LaunchAgents
	@sed "s|__HOME__|$(HOME)|g" scripts/no.aursand.astronomy-auto-update.plist.tpl \
		> $(HOME)/Library/LaunchAgents/no.aursand.astronomy-auto-update.plist
	@launchctl bootout gui/$(shell id -u)/no.aursand.astronomy-auto-update 2>/dev/null || true
	@launchctl bootstrap gui/$(shell id -u) $(HOME)/Library/LaunchAgents/no.aursand.astronomy-auto-update.plist
	@echo "launchd agent installed + loaded (unload: launchctl bootout gui/$(shell id -u)/no.aursand.astronomy-auto-update)"

# Build+push the UID-150 testapp image to GHCR.
.PHONY: testapp-image
testapp-image:
	$(MAKE) ghcr-login
	@docker buildx create --name multi --driver docker-container --use >/dev/null 2>&1 || true
	@SHA=$$(git -C . rev-parse HEAD); \
	docker buildx build --platform linux/arm64 --push \
		-t $(TESTAPP_IMAGE):main-$$SHA \
		-t $(TESTAPP_IMAGE):latest \
		-f testapp/Dockerfile testapp

.PHONY: astronomy astronomy-secrets astronomy-cert astronomy-verify astronomy-ingest-wait

# Idempotently ensure the astronomy-db-creds secrets (astronomy-db: full env,
# astronomy: ASTRONOMY_* keys only) exist from the gitignored .env.astronomy.
.PHONY: astronomy-secrets
astronomy-secrets:
	@test -f $(ASTRONOMY_ENV) || { echo "missing $(ASTRONOMY_ENV) (gitignored)"; exit 1; }
	@kubectl --context $(KUBECTX) create secret generic astronomy-db-creds -n astronomy-db --from-env-file=$(ASTRONOMY_ENV) --dry-run=client -o yaml | kubectl --context $(KUBECTX) apply -f - >/dev/null
	@grep '^ASTRONOMY_' $(ASTRONOMY_ENV) > /tmp/.astronomy-app.env
	@kubectl --context $(KUBECTX) create secret generic astronomy-db-creds -n astronomy --from-env-file=/tmp/.astronomy-app.env --dry-run=client -o yaml | kubectl --context $(KUBECTX) apply -f - >/dev/null
	@rm -f /tmp/.astronomy-app.env
	@echo "astronomy-secrets: OK"

# Copy the app TLS secret from istio-gateways into astronomy (Gateway
# credentialName resolves in the app namespace; cert name has a hash, so the
# Certificate is found by label and its spec.secretName used).
.PHONY: astronomy-cert
astronomy-cert:
	@CERT=$$(kubectl --context $(KUBECTX) -n istio-gateways get certificate -l app.kubernetes.io/name=astronomy-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	test -n "$$CERT" || { echo "astronomy-cert: Certificate not found (Application not reconciled?)"; exit 1; }; \
	echo "astronomy-cert: waiting for $$CERT..."; \
	kubectl --context $(KUBECTX) -n istio-gateways wait --for=condition=Ready certificate/$$CERT --timeout=120s >/dev/null; \
	SEC=$$(kubectl --context $(KUBECTX) -n istio-gateways get certificate $$CERT -o jsonpath='{.spec.secretName}'); \
	kubectl --context $(KUBECTX) -n istio-gateways get secret $$SEC -o yaml \
		| sed -e 's/namespace: istio-gateways/namespace: astronomy/' -e '/^  uid:/d' -e '/^  resourceVersion:/d' -e '/^  creationTimestamp:/d' \
		| kubectl --context $(KUBECTX) apply -f - >/dev/null
	@echo "astronomy-cert: TLS secret synced"

# Smoke-test the astronomy demo end to end (fail-fast).
.PHONY: astronomy-verify
astronomy-verify:
	@lsof -i :8443 -sTCP:LISTEN >/dev/null 2>&1 || $(MAKE) pf
	@echo "== astronomy verify =="
	@argocd app get k8s-apps | grep -q 'Sync Status:.*Synced' && argocd app get k8s-apps | grep -q 'Health Status:.*Healthy' && echo "  argo: OK" || { echo "  argo: FAIL"; exit 1; }
	@kubectl --context $(KUBECTX) -n astronomy-db exec deploy/astronomy-db -- pg_isready -U astronomy -d astronomy >/dev/null 2>&1 && echo "  postgres: OK" || { echo "  postgres: FAIL"; exit 1; }
	@kubectl --context $(KUBECTX) -n astronomy get po -l app=astronomy-api -o jsonpath='{.items[0].status.phase}' | grep -q Running && echo "  astronomy-api: OK" || { echo "  astronomy-api: FAIL"; exit 1; }
	@kubectl --context $(KUBECTX) -n astronomy get hpa astronomy-api >/dev/null 2>&1 && echo "  hpa: OK" || { echo "  hpa: FAIL"; exit 1; }
	@curl -s -m 15 --cacert /tmp/local-ca.crt --connect-to $(ASTRONOMY_HOST):443:127.0.0.1:8443 https://$(ASTRONOMY_HOST)/health/ready | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('status')=='ready' and d.get('db')=='ok' and d.get('kernels')=='ok' and d.get('starCatalog')=='ok', d" && echo "  /health/ready: OK" || { echo "  /health/ready: FAIL"; exit 1; }
	@curl -s -m 20 --cacert /tmp/local-ca.crt --connect-to $(ASTRONOMY_HOST):443:127.0.0.1:8443 "https://$(ASTRONOMY_HOST)/api/v1/ephemeris/sun/position" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('rightAscensionDeg'), d" && echo "  sun position: OK" || { echo "  sun position: FAIL"; exit 1; }
	@echo "== astronomy demo: ALL OK =="

# Wait for the three one-shot ingest Jobs to complete (naif downloads kernels,
# so this can take ~10 min on a fresh cluster).
.PHONY: astronomy-ingest-wait
astronomy-ingest-wait:
	@for j in ingest-datasets ingest-naif ingest-omm; do \
		echo "waiting job $$j..."; \
		kubectl --context $(KUBECTX) -n astronomy wait --for=condition=Complete job/$$j --timeout=1500s >/dev/null 2>&1 || { echo "job $$j did not complete"; exit 1; }; \
	done
	@echo "ingest jobs: all Complete"

# Bootstrap the astronomy demo end to end (idempotent). Assumes the base stack
# exists (make cluster); starts operator/port-forwards if down.
.PHONY: astronomy
astronomy:
	@echo "== astronomy bootstrap =="
	@kubectl --context $(KUBECTX) get nodes >/dev/null 2>&1 || { echo "cluster not running — run: make cluster"; exit 1; }
	@pgrep -f 'bin/skiperator' >/dev/null || { echo "starting operator..."; $(MAKE) operator >/dev/null 2>&1; sleep 20; }
	@lsof -i :8443 -sTCP:LISTEN >/dev/null 2>&1 || $(MAKE) pf >/dev/null 2>&1
	@$(MAKE) astronomy-secrets
	@echo "-- argo sync --"; argocd app sync k8s-apps >/dev/null 2>&1 || true
	@echo "-- wait postgres --"; kubectl --context $(KUBECTX) -n astronomy-db rollout status deploy/astronomy-db --timeout=180s >/dev/null 2>&1 || { echo "postgres not ready"; exit 1; }
	@$(MAKE) astronomy-ingest-wait
	@echo "-- wait astronomy-api --"; kubectl --context $(KUBECTX) -n astronomy rollout status deploy/astronomy-api --timeout=300s >/dev/null 2>&1 || { echo "astronomy-api not ready"; exit 1; }
	@$(MAKE) astronomy-cert
	@$(MAKE) astronomy-verify
