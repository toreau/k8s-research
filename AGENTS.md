# AGENTS.md — k8s-research

Local Kubernetes testing stack on a MacBook Pro (arm64 / macOS 26): **kind** +
**Skiperator** (Kartverket operator) + **ArgoCD** (GitOps).

Precedence: this file governs this repo; the global `~/.config/opencode/AGENTS.md`
still governs memory/search routing and mutation policy.

Full durable detail: Docmost **`Projects/k8s-research`**. Build history:
`Work Logs/2026-08-24 k8s-research Phase 0 — local Skiperator/ArgoCD stack setup`.

## Architecture at a glance

```
apps/ (git) → ArgoCD (auto-sync+self-heal) → Skiperator CRs → operator (host binary) → k8s resources
       git daemon 127.0.0.1:9418 (host), reached from kind via host.docker.internal
```

Cluster `kind-skiperator` (k8s **1.34.3**). Istio **1.30.3** (istiod + custom external
gateway), cert-manager **1.21.1**, MetalLB **0.16.1** (external gateway LB `172.21.255.200`),
ArgoCD **10.4.0** (helm), metrics-server **0.9.0**, Skiperator **v2.18.0** (main @ clone).

## Repo layout

- `apps/` — GitOps-managed: Skiperator CRs (hello, sample-two, sample-routing, SKIPJobs) + astronomy-demo (postgres, ingest, api) + `tools/` (cert-sync CronJob) + `observability/` (Prometheus operator + Prometheus + istiod/envoy scrapes + Grafana)
- `cluster/` — applied directly: `metallb/`, `istio-gateways/`, `metrics-server/`
- `argocd/` — helm values + root Application `k8s-apps.yaml`
- `testapp/` — UID-150 Go test app image (pushed to `ghcr.io/toreau/k8s-testapp`)
- `skiperator/` — upstream clone, own repo (git-ignored); its `AGENTS.md` governs edits inside it

## Key commands

```bash
make status          # cluster + processes + ArgoCD app state (start here)
make operator        # operator host binary in background (log /tmp/skiperator-operator.log); operator-stop
make serve-git       # git daemon for ArgoCD (127.0.0.1:9418);                    git-stop
make pf              # port-forwards: ArgoCD UI 8081, istio HTTPS 8443;           pf-stop
make cluster         # create kind-skiperator + all deps (skiperator: make setup-local)
make astronomy       # bootstrap the astronomy demo end-to-end (idempotent)
make astronomy-verify # smoke-test the demo (fail-fast); astronomy-cert / astronomy-secrets
make astronomy-image # build+push arm64 + merge multi-arch GHCR manifest (CI pushes amd64)
make observability   # bootstrap Prometheus+Grafana (monitoring ns, exclusions, sync)
make pf-grafana      # port-forwards: Grafana 3000 (admin/admin), Prometheus 9090
make verify          # tool versions
```

- ArgoCD UI: http://127.0.0.1:8081 · admin pw: `/tmp/argocd-admin.txt`
- HTTPS test: `curl --cacert /tmp/local-ca.crt --connect-to <host>:443:127.0.0.1:8443 https://<host>/`
  (CA: extract `ca.crt` from `cert-manager/local-test-ca`)

## Workflows

- **Start stack**: `make status` → `make operator serve-git pf` (processes are not reboot-persistent).
- **Astronomy demo (fresh cluster)**: `make cluster` → `make astronomy` (starts operator/git/pf, syncs, waits for ingest, copies cert, verifies).
- **Iterate an app image**: push the image to GHCR (CI or `make astronomy-image`/`testapp-image`) → update the digest in `apps/*` → commit → `argocd app sync k8s-apps`.
- **New namespace**: create it, add to `namespace-exclusions` ConfigMap (`skiperator-system`), delete any stale default-deny NetPol.
- **GitOps change**: edit `apps/*`, commit (git daemon serves this working repo), `argocd app sync`.
- **Teardown**: `make cluster-delete` (also `git-stop`/`pf-stop`/`operator-stop`).

## Verification cheat-sheet

```bash
make status
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

**Ingress / networking**
- Skiperator's Gateways select `app: istio-ingress-external` in `istio-gateways` (provisioned in `cluster/istio-gateways/`); needs `ISTIO_META_CLUSTER_ID=Kubernetes` + cluster-scoped secrets RBAC for its SA, or istiod won't serve app certs via SDS.
- App certs are created in `istio-gateways`, but the per-app Gateway's `credentialName` resolves in the **app namespace** — copy the TLS secret (tls.crt/key/ca.crt) there after each reconcile (`make astronomy-cert`, or the `cert-sync` CronJob in `default` re-syncs automatically).
- **istio 1.30.3 sidecars blackhole outbound to external (non-mesh) hosts** (REGISTRY_ONLY behavior: `BlackHoleCluster`/502) even with `meshConfig.outboundTrafficPolicy: ALLOW_ANY` set — external HTTPS from a sidecar'd workload gets TLS EOF. Workaround: run external-HTTPS workloads sidecar-free (`sidecar.istio.io/inject: "false"`, as the ingest Jobs do). Documented finding; upstream issue not yet filed.
- Docker Desktop host **cannot route to the kind bridge subnet** — use the port-forward for host access.
- **SNI comes from the URL hostname**, not `Host:` — use `--connect-to`/`--resolve`.

**GitOps / ArgoCD**
- `kubectl get application` resolves to the ArgoCD kind — use `applications.skiperator.kartverket.no` for Skiperator CRs.
- ArgoCD manages the Skiperator **CRs**, not the operator-generated Deployment (self-heal acts at CR level).
- git daemon is unauthenticated — loopback only; not reboot-persistent.

## Conventions

- `apps/` = GitOps-managed; `cluster/` = applied directly.
- Never commit secrets (ArgoCD admin pw etc.) — read from cluster, note paths.
- Work logs → Docmost `Work Logs/`; durable stack docs → `Projects/k8s-research`.
