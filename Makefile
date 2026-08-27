SHELL = bash
.DEFAULT_GOAL = help

SKIPERATOR_DIR := skiperator
KIND_CLUSTER_NAME ?= skiperator
KUBECTX := kind-$(KIND_CLUSTER_NAME)
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
	@echo "  make testapp-image   build+push UID-150 testapp image to GHCR"
	@echo "  make astronomy       bootstrap the astronomy demo (secrets/sync/ingest/cert/verify)"
	@echo "  make astronomy-secrets  ensure astronomy-db-creds secrets (from .env.astronomy)"
	@echo "  make astronomy-cert     copy the app TLS secret from istio-gateways into astronomy"
	@echo "  make astronomy-verify   smoke-test the astronomy demo (fail-fast)"
	@echo "  make observability   bootstrap Prometheus+Grafana (exclusions, sync, pf-grafana)"
	@echo "  make policy-controller  bootstrap Sigstore Policy Controller + GitHub trust-policies (attestation enforcement)"
	@echo "  make protect-main    protect main: require PRs + validate/argocd/gate-pr checks + 1 review"
	@echo "  make pf-grafana      port-forwards: Grafana 3000, Prometheus 9090"

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

.PHONY: policy-controller
policy-controller:
	@echo "== policy-controller bootstrap (SLSA attestation enforcement) =="
	@kubectl --context $(KUBECTX) get nodes >/dev/null 2>&1 || { echo "cluster not running — run: make cluster"; exit 1; }
	@kubectl --context $(KUBECTX) -n skiperator-system patch cm namespace-exclusions --type merge -p '{"data":{"artifact-attestations":"true"}}' >/dev/null 2>&1 || true
	@kubectl --context $(KUBECTX) -n artifact-attestations delete networkpolicy default-deny --ignore-not-found >/dev/null 2>&1 || true
	# Install only if absent: a re-run of `helm upgrade` on an existing install
	# conflicts on the webhook namespaceSelector (the policy-controller's Knative
	# reconciler owns that field), so the charts are treated as install-once.
	@helm status policy-controller -n artifact-attestations 2>/dev/null | grep -q 'STATUS: deployed' || \
		helm upgrade policy-controller --install --create-namespace -n artifact-attestations \
			oci://ghcr.io/sigstore/helm-charts/policy-controller --version 0.10.5 \
			-f cluster/attestations/values-policy-controller.yaml
	@helm status trust-policies -n artifact-attestations 2>/dev/null | grep -q 'STATUS: deployed' || \
		helm upgrade trust-policies --install -n artifact-attestations \
			oci://ghcr.io/github/artifact-attestations-helm-charts/trust-policies --version v0.7.0 \
			-f cluster/attestations/values-trust-policies.yaml
	@kubectl --context $(KUBECTX) label ns astronomy policy.sigstore.dev/include=true --overwrite >/dev/null 2>&1 || true
	@kubectl --context $(KUBECTX) -n artifact-attestations rollout status deploy/policy-controller-webhook --timeout=120s >/dev/null 2>&1 || { echo "policy-controller-webhook not ready"; exit 1; }
	@kubectl --context $(KUBECTX) -n artifact-attestations get trustroot github -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True || { echo "trustroot github not Ready"; exit 1; }
	@echo "== policy-controller: webhook Running + TrustRoot Ready, enforcement on astronomy =="

# Re-apply trust-policies values (e.g. after a subjectRegExp change). Unlike
# `make policy-controller`, this is NOT install-once-gated: a plain `helm upgrade`
# of the trust-policies release updates the TrustRoot/ClusterImagePolicy CRs and
# does not touch the policy-controller webhook namespaceSelector.
.PHONY: trust-policies-values
trust-policies-values:
	@helm upgrade trust-policies -n artifact-attestations \
		oci://ghcr.io/github/artifact-attestations-helm-charts/trust-policies --version v0.7.0 \
		-f cluster/attestations/values-trust-policies.yaml
	@kubectl --context $(KUBECTX) -n artifact-attestations get clusterimagepolicy github-policy -o jsonpath='{range .spec.authorities[*].keyless.identities[*]}{.subjectRegExp}{"\n"}{end}' 2>/dev/null | sed 's/^/subjectRegExp now: /' || true
	@echo "== trust-policies re-applied =="

# Protect main (GitOps guardrails): require PRs with the validate-apps/validate-argocd/
# gate-pr checks + 1 review before merge. Idempotent PUT; needs `gh` authenticated.
# enforce_admins=false so the admin can still hotfix main directly.
.PHONY: protect-main
protect-main:
	@./scripts/protect-main.sh

# Sync all ArgoCD apps except astronomy: parent first, then the 5 apps in
# dependency order (observability-base before prometheus-platform so the
# monitoring namespace exists; then grafana; cert-sync/sample-apps independent).
# Apps are automated, so this is mostly a fast confirmation + apply of new
# commits. ASTRONOMY IS EXCLUDED: its ingest Jobs carry
# `argocd.argoproj.io/sync-options: Force=true,Replace=true` (recreated on every
# sync → re-runs data ingestion), so it is rolled deliberately via
# `make app-roll NAME=astronomy` (or by auto-sync after a digest-bump merge).
ARGO_APPS := astronomy observability-base prometheus-platform grafana cert-sync sample-apps
ARGO_APPS_SYNC := $(filter-out astronomy,$(ARGO_APPS))

.PHONY: argo-sync
argo-sync:
	@echo "== argo sync (excl. astronomy; roll it via app-roll) =="
	@argocd app sync k8s-apps >/dev/null 2>&1 || true
	@for app in $(ARGO_APPS_SYNC); do \
		echo "  syncing $$app"; \
		argocd app sync $$app >/dev/null 2>&1 || { echo "  $$app: FAIL"; exit 1; }; \
	done
	@echo "argo-sync: 5 apps synced"

# Force-sync one ArgoCD app (delete + re-apply). The generic roll for apps whose
# jobs carry the Force=true sync option (e.g. astronomy's ingest Jobs).
.PHONY: app-roll
app-roll:
	@[ -n "$(NAME)" ] || { echo "usage: make app-roll NAME=<app>"; exit 1; }
	@argocd app sync $(NAME) --force >/dev/null 2>&1 || { echo "$(NAME): FAIL"; exit 1; }
	@echo "app-roll: $(NAME) force-synced"

# HTTPS smoke-test for an app via the istio port-forward.
.PHONY: app-verify
app-verify:
	@[ -n "$(NAME)" ] && [ -n "$(HOST)" ] || { echo "usage: make app-verify NAME=<app> HOST=<host>"; exit 1; }
	@curl -fsS --cacert /tmp/local-ca.crt --connect-to $(HOST):443:127.0.0.1:8443 https://$(HOST)/ >/dev/null \
		&& echo "app-verify: https://$(HOST)/ OK" || { echo "app-verify: FAIL"; exit 1; }

# Scaffold a new app (see apps/README.md): generates apps/<name>/, meta.yaml and
# the ArgoCD Application, patches namespace-exclusions and drops the stale
# default-deny. Commit + push, then `make app-roll NAME=<name>`.
.PHONY: app-onboard
app-onboard:
	@[ -n "$(NAME)" ] && [ -n "$(IMAGE)" ] && [ -n "$(HOST)" ] && [ -n "$(PORT)" ] && [ -n "$(REPO)" ] \
		|| { echo "usage: make app-onboard NAME=<name> IMAGE=<ref incl. digest> HOST=<host> PORT=<port> REPO=<owner/repo> [BUILD_TYPE=…] [ATTESTATION=…]"; exit 1; }
	@./scripts/app-onboard.sh "$(NAME)" "$(IMAGE)" "$(HOST)" "$(PORT)" "$(REPO)" "$(BUILD_TYPE)" "$(ATTESTATION)"
	@kubectl --context $(KUBECTX) -n skiperator-system patch cm namespace-exclusions --type merge -p "{\"data\":{\"$(NAME)\":\"true\"}}" >/dev/null 2>&1 || true
	@kubectl --context $(KUBECTX) -n $(NAME) delete networkpolicy default-deny --ignore-not-found >/dev/null 2>&1 || true
	@echo "== app-onboard: commit + push apps/$(NAME)/ argocd/apps/$(NAME).yaml, then make app-roll NAME=$(NAME) =="

.PHONY: status
status:
	@echo "== cluster =="; kubectl --context $(KUBECTX) get nodes --no-headers 2>/dev/null | awk '{print $$1, $$2}' || echo "cluster not running"
	@echo "== operator =="; pgrep -f 'bin/skiperator' >/dev/null && echo "running" || echo "stopped"
	@echo "== port-forwards =="; lsof -i :8081 -sTCP:LISTEN >/dev/null 2>&1 && echo "argocd 8081 up" || echo "argocd 8081 down"; lsof -i :8443 -sTCP:LISTEN >/dev/null 2>&1 && echo "istio 8443 up" || echo "istio 8443 down"
	@echo "== argo apps =="; kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null || echo "n/a"
	@echo "== attestations =="; kubectl --context $(KUBECTX) -n artifact-attestations get deploy policy-controller-webhook --no-headers 2>/dev/null | awk '{print "webhook ready " $$2" ("$$1")"}' | grep . || echo "webhook n/a"; kubectl --context $(KUBECTX) -n artifact-attestations get trustroot github -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}' 2>/dev/null | grep . | sed 's/^/trustroot ready: /' || echo "trustroot n/a"; kubectl --context $(KUBECTX) get ns astronomy -o jsonpath='{.metadata.labels.policy\.sigstore\.dev\/include}{"\n"}' 2>/dev/null | grep . | sed 's/^/astronomy include: /' || echo "astronomy include n/a"

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
	@kubectl --context $(KUBECTX) -n skiperator-system patch cm namespace-exclusions --type merge -p '{"data":{"astronomy-db":"true"}}' >/dev/null 2>&1 || true
	@kubectl --context $(KUBECTX) -n astronomy-db delete networkpolicy default-deny --ignore-not-found >/dev/null 2>&1 || true
	@$(MAKE) astronomy-secrets
	@echo "-- argo sync --"; argocd app sync k8s-apps >/dev/null 2>&1 || true; argocd app sync astronomy --force >/dev/null 2>&1 || true
	@echo "-- wait postgres --"; kubectl --context $(KUBECTX) -n astronomy-db rollout status deploy/astronomy-db --timeout=180s >/dev/null 2>&1 || { echo "postgres not ready"; exit 1; }
	@$(MAKE) astronomy-ingest-wait
	@echo "-- wait astronomy-api --"; kubectl --context $(KUBECTX) -n astronomy rollout status deploy/astronomy-api --timeout=300s >/dev/null 2>&1 || { echo "astronomy-api not ready"; exit 1; }
	@$(MAKE) astronomy-cert
	@$(MAKE) astronomy-verify
