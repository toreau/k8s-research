# AGENTS.md — k8s-research

Local Kubernetes testing stack on a MacBook Pro (arm64 / macOS 26): **kind** +
**Skiperator** (Kartverket operator) + **ArgoCD** (GitOps).

Precedence: this file governs this repo; the global `~/.config/opencode/AGENTS.md`
still governs memory/search routing and mutation policy.

Full durable detail: Docmost **`Projects/k8s-research`**. Build history:
`Work Logs/2026-08-24 k8s-research Phase 0 — local Skiperator/ArgoCD stack setup`.

## Architecture at a glance

```
apps/ (git, GitHub toreau/k8s-research) → ArgoCD (auto-sync+self-heal) → Skiperator CRs → operator (host binary) → k8s resources
```

Cluster `kind-skiperator` (k8s **1.34.3**). Istio **1.30.3** (istiod + custom external
gateway), cert-manager **1.21.1**, MetalLB **0.16.1** (external gateway LB `172.21.255.200`),
ArgoCD **10.4.0** (helm), metrics-server **0.9.0**, Skiperator **v2.18.0** (main @ clone).

ArgoCD is **app-of-apps**: root `k8s-apps` (path `argocd/apps`) manages 6
Applications — `astronomy` and `prometheus-platform` are direct workload apps
(the astronomy demo, resp. the Prometheus operator/prometheus/scrapes), the rest
are single apps (grafana, observability-base, cert-sync, sample-apps). 7 ArgoCD
apps in total. Observability (`monitoring` ns) is a **shared, app-agnostic
platform**: any istio-injected namespace's sidecar is auto-scraped.

## Repo layout

- `apps/` — GitOps-managed, one directory per ArgoCD app: `sample/` (hello, sample-two, routing, SKIPJobs), `astronomy/` (api + `db/` postgres + `infra/` ns/PVC/netpols + `ingest/` 3 Jobs), `observability/{base,platform,grafana}/` (shared platform + Grafana), `tools/` (cert-sync CronJob)
- `cluster/` — applied directly: `metallb/`, `istio-gateways/`, `metrics-server/`, `kyverno/` (SLSA image-attestation policy)
- `argocd/` — helm values + root Application `k8s-apps.yaml` + `apps/*.yaml` (6 Applications: astronomy, prometheus-platform, grafana, observability-base, cert-sync, sample-apps)
- `testapp/` — UID-150 Go test app image (pushed to `ghcr.io/toreau/k8s-testapp`)
- `skiperator/` — upstream clone, own repo (git-ignored); its `AGENTS.md` governs edits inside it
- `.github/workflows/validate.yml` — CI: kubeconform + yamllint over `apps/` and `argocd/apps/` (Skiperator CRD schemas in `ci/schemas/`)

## Key commands

```bash
make status          # cluster + processes + all ArgoCD apps (start here)
make argo-sync       # sync all ArgoCD apps (parent + 6 apps, in order)
make operator        # operator host binary in background (log /tmp/skiperator-operator.log); operator-stop
make pf              # port-forwards: ArgoCD UI 8081, istio HTTPS 8443;           pf-stop
make cluster         # create kind-skiperator + all deps (skiperator: make setup-local)
make astronomy       # bootstrap the astronomy demo end-to-end (idempotent)
make astronomy-verify # smoke-test the demo (fail-fast); astronomy-cert / astronomy-secrets
make observability   # bootstrap Prometheus+Grafana (monitoring ns, exclusions, argo-sync)
make pf-grafana      # port-forwards: Grafana 3000 (admin/admin), Prometheus 9090
make verify          # tool versions
```

- ArgoCD UI: http://127.0.0.1:8081 · admin pw: `/tmp/argocd-admin.txt`
- HTTPS test: `curl --cacert /tmp/local-ca.crt --connect-to <host>:443:127.0.0.1:8443 https://<host>/`
  (CA: extract `ca.crt` from `cert-manager/local-test-ca`)

## Workflows

- **Start stack**: `make status` → `make operator pf` (processes are not reboot-persistent).
- **Astronomy demo (fresh cluster)**: `make cluster` → install ArgoCD + `argocd repo add https://github.com/toreau/k8s-research.git --username toreau --password <token>` (private repo) + `kubectl apply -f argocd/k8s-apps.yaml` → `make astronomy` (starts operator/pf, syncs, waits for ingest, copies cert, verifies).
- **Iterate an app image (astronomy) — fully cloud-driven**: push to `astronomy.aursand.no` `main` → CI builds **multi-arch** (amd64 `ubuntu-latest` + arm64 `ubuntu-24.04-arm` matrix) → merges the manifest (`main-<sha>`, `latest`) → dispatches k8s-research (`astro-image-pushed` with `{sha, digest}`) → `astro-digest-bump.yml` bumps the digest in `apps/astronomy/api.yaml` (only that file) → ArgoCD auto-syncs from GitHub → cluster rolls. Zero Mac involvement beyond hosting the cluster. Cross-repo auth: `K8S_RESEARCH_PAT` (secret in the astronomy repo; dispatch to k8s-research; currently the `gh auth token`). Bump pushes use GITHUB_TOKEN (same repo → no CI re-trigger).
- **Iterate another app's image**: push the image to GHCR → update the digest in `apps/*` → commit **and push** → ArgoCD auto-syncs (`make argo-sync` for an immediate manual sync).
- **New namespace**: create it, add to `namespace-exclusions` ConfigMap (`skiperator-system`), delete any stale default-deny NetPol.
- **GitOps change**: edit `apps/*`, commit **and push** to `origin` (ArgoCD auto-syncs from GitHub; use `make argo-sync` for an immediate manual sync, or sync only the affected app). No local git daemon involved.
- **Observability onboarding (new app)**: sidecar metrics are auto-scraped, but the app namespace must allow ingress TCP 15090 from `monitoring` (see `apps/astronomy/infra/allow-prometheus-envoy.yaml`). App-own `/metrics` → ServiceMonitor/PodMonitor labeled `app.kubernetes.io/name: observability`. Dashboards → provisioned ConfigMap. Full pattern: `apps/observability/README.md`.
- **Teardown**: `make cluster-delete` (also `pf-stop`/`operator-stop`).

## Verification cheat-sheet

```bash
make status
make argo-sync
kubectl -n argocd get applications          # 7 apps (parent + 6)
argocd app get k8s-apps
kubectl -n sample get applications.skiperator.kartverket.no,routing,skipjob,cronjob,hpa,po
kubectl -n istio-gateways get svc istio-ingress-external,gateways.networking.istio.io
curl --cacert /tmp/local-ca.crt --connect-to sample-two.172.21.255.200.nip.io:443:127.0.0.1:8443 https://sample-two.172.21.255.200.nip.io/
```

## Gotchas

**Skiperator / operator**
- App images must run as **UID 150** (hardcoded) — `testapp/` shows the pattern.
- Reconcilers need the `skiperator-config` / `docker-config` / `github-config` ConfigMaps (`make setup-local` applies them).
- `skiperator-config` has `enableLocallyBuiltImages: false` → normal imagePull + Skiperator image→digest resolution (registry creds in `skiperator-system/github-config`; the per-namespace `github-auth` imagePullSecret is built by the operator from that token, so the stored value must be `base64(user:token)`, i.e. `.data.token` double-base64). The flag lives in the clone's `config/skiperator-config.yaml` (edit there — `make run-operator` re-applies it, resetting the ConfigMap).
- HPA (`replicas: {min,max,targetCpuUtilization}`) needs a CPU `request` on the Application or reports "missing request for cpu".
- **SKIPJob ignored `enableLocallyBuiltImages`** (imagePullPolicy was hardcoded `PullAlways`) — patched locally in the clone (`pkg/resourcegenerator/pod` + `job`, `CreateJobContainer` now takes `LocalBuiltImages`); rebuild via `make operator`. Upstream proposal not yet sent.
- Namespace controller default-denies (Ingress+Egress) every namespace not in `namespace-exclusions` — non-istio workloads in new namespaces break.
- **SLSA / Kyverno** (cluster/kyverno/): use the **`ImageValidatingPolicy`** (`policies.kyverno.io/v1`, stable in v1.19) with CEL `verifyAttestationSignatures` — the legacy `ClusterPolicy` `verifyImages`/`SigstoreBundle` path is deprecated (removal in v1.20) and fails on GitHub artifact attestations ("no matching signatures found"). `credentials.secrets` (regcred in the `kyverno` ns, created outside git) provides GHCR auth for the private astronomy package; keyless attestor = subject `…/ci.yml@refs/heads/main` + issuer `https://token.actions.githubusercontent.com`, ctlog `rekor.sigstore.dev`. Add `kyverno` to `namespace-exclusions` and delete its stale default-deny NetPol (or Kyverno's own webhooks break).

**Ingress / networking**
- Skiperator's Gateways select `app: istio-ingress-external` in `istio-gateways` (provisioned in `cluster/istio-gateways/`); needs `ISTIO_META_CLUSTER_ID=Kubernetes` + cluster-scoped secrets RBAC for its SA, or istiod won't serve app certs via SDS.
- App certs are created in `istio-gateways`, but the per-app Gateway's `credentialName` resolves in the **app namespace** — copy the TLS secret (tls.crt/key/ca.crt) there after each reconcile (`make astronomy-cert`, or the `cert-sync` CronJob in `default` re-syncs automatically).
- **istio 1.30.3 sidecars blackhole outbound to external (non-mesh) hosts** (REGISTRY_ONLY behavior: `BlackHoleCluster`/502) even with `meshConfig.outboundTrafficPolicy: ALLOW_ANY` set — external HTTPS from a sidecar'd workload gets TLS EOF. Workaround: run external-HTTPS workloads sidecar-free (`sidecar.istio.io/inject: "false"`, as the ingest Jobs do). Documented finding; upstream issue not yet filed.
- Docker Desktop host **cannot route to the kind bridge subnet** — use the port-forward for host access.
- **SNI comes from the URL hostname**, not `Host:` — use `--connect-to`/`--resolve`.

**GitOps / ArgoCD**
- `kubectl get application` resolves to the ArgoCD kind — use `-n argocd` (7 apps now) or `applications.skiperator.kartverket.no` for Skiperator CRs.
- App-of-apps: `k8s-apps` manages the 6 Applications; `astronomy` and `prometheus-platform` are direct workload apps owning their resources (tracking-annotation `argocd.argoproj.io/tracking-id`). Sync order matters for runtime deps (astronomy; observability-base → prometheus-platform → grafana; then cert-sync/sample-apps) — `make argo-sync` does it.
- **ArgoCD automation gotcha**: `syncPolicy.automated` being present keeps auto-sync ON even with `prune: false`/`selfHeal: false` — those only disable pruning/self-healing. To fully pause auto-sync set `syncPolicy.automated: null`.
- ArgoCD manages the Skiperator **CRs**, not the operator-generated Deployment (self-heal acts at CR level).
- ArgoCD sources the **private** `https://github.com/toreau/k8s-research.git` with a GitHub token stored in `argocd-repo-secret` (added via `argocd repo add --username toreau --password <token>`; currently the `gh auth token` — rotate if it needs to be revoked). Fresh clusters need this repo-add step (with a token) before apps can sync.

## Conventions

- `apps/` = GitOps-managed; `cluster/` = applied directly.
- Never commit secrets (ArgoCD admin pw etc.) — read from cluster, note paths.
- Work logs → Docmost `Work Logs/`; durable stack docs → `Projects/k8s-research`.
