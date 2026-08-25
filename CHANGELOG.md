# Changelog

## 2026-08-25

### Infrastructure & ops
- ArgoCD **app-of-apps (flat, 7 apps)**: root `k8s-apps` (path `argocd/apps/`) manages 6 Applications — `astronomy` (the demo: api + `db/` postgres + `infra/` ns/PVC/netpols + `ingest/` 3 Jobs; path `apps/astronomy`, recursive), `prometheus-platform` (Prometheus operator + Prometheus + istiod/envoy scrapes; path `apps/observability/platform`), `observability-base` (monitoring ns), `grafana`, `cert-sync`, `sample-apps`. `make argo-sync` syncs all in dependency order; `make status` lists every app. (Iterated during the day via 11 per-component apps → 14 with nested groups → merged to the final 7 to declutter the Applications list.)
- Observability as a **shared, app-agnostic platform**: envoy PodMonitor + istiod ServiceMonitor in `prometheus-platform` scrape any istio-injected namespace; per-app onboarding = ServiceMonitor/PodMonitor labeled `app.kubernetes.io/name: observability` + a TCP 15090 ingress NetPol in the app namespace (pattern in `apps/observability/README.md` and AGENTS.md).
- Repo layout grouped per ArgoCD app (`apps/sample/`, `apps/astronomy/{api.yaml,db/,infra/,ingest/}`, `apps/observability/{base,platform,grafana}/`, `apps/tools/`); migrations done with zero workload deletions (ArgoCD resource ownership moved via tracking annotations).
- CI (`validate.yml`) now also runs kubeconform + yamllint over `argocd/apps/`.

### Bugs fixed
- `make observability` checked `deploy/prometheus-operator` in `monitoring`, but the operator Deployment/SA live in `default` (per manifest) — the rollout gate always failed. Now checks `-n default`.
- Envoy `PodMonitor` scraped the same pod **3×** (one target per container: app/istio-init/istio-proxy, all mapped to pod IP:15090). Added a `keep` relabeling on `__meta_kubernetes_pod_container_name = istio-proxy` — one target per sidecar pod (target count per mesh pod 3→1, verified via onboarding demo).

## 2026-08-24

### Core
- Local Kubernetes testing stack: kind `skiperator` (k8s 1.34.3) + Skiperator + ArgoCD GitOps.
- Astronomy demo: `astronomy.aursand.no` also deployed into the local stack (same repo/image, two environments) — dedicated Postgres, SPICE-kernel + dataset ingest, Skiperator Application with HPA and HTTPS on `astronomy.172.21.255.200.nip.io`.
- Reproducible demo: `make astronomy` bootstraps secrets, syncs ArgoCD, waits for Postgres + ingest Jobs, copies the TLS cert and smoke-verifies — idempotent after `make cluster-delete` → `make cluster`.
- Astronomy image runs as **UID 150** (matches Skiperator's enforced securityContext; prod on Coolify now runs as 150).

### Infrastructure & ops
- **CI: `kubeconform` + `yamllint` over `apps/`** (`.github/workflows/validate.yml`) with Skiperator CRD schemas committed under `ci/schemas/`; istio/monitoring CRs ignored.

### Infrastructure & ops
- ArgoCD `k8s-apps` root Application made cluster-wide and recursive (`source.directory.recurse`) so `apps/` subdirectories are synced.
- GitOps-managed Postgres (`apps/astronomy-db/`) and astronomy namespace (`apps/astronomy/`) with default-deny + explicit egress/ingress NetworkPolicies.
- Data ingest as plain `batch/v1` Jobs (sidecar-free) — Skiperator `SKIPJob` forces `PullAlways`, incompatible with local images.
- One artifact, two environments: astronomy Dockerfile made multi-arch and upstreamed; CI pushes `ghcr.io/toreau/astronomy-api` (amd64), local `make astronomy-image` builds arm64 and merges the multi-arch manifest; `enableLocallyBuiltImages` off — all apps registry-backed (GHCR digest-pins, `github-auth` imagePullSecret wired from `github-config` auth blob).
- `cert-sync` CronJob (`apps/tools/`) in the `default` namespace (exempt from default-deny, so it can reach the kube-apiserver) re-copies the app TLS secret from `istio-gateways` into `astronomy` on a schedule; RBAC `get`+`list` on certificates (label selectors require `list`).
- Observability (`apps/observability/`): upstream prometheus-operator v0.93.1 (matches the setup-local CRDs), minimal `Prometheus` CR (SA + ClusterRole for k8s service discovery), ServiceMonitor for istiod (15014) and PodMonitor for envoy sidecars (15090 via pod-IP relabel — the merged 15020 isn't reachable from the pod IP), Grafana with the three istio dashboards (provisioned ConfigMaps). Gotchas: dashboards ConfigMap was too large for ArgoCD's last-applied annotation (split into 3); app namespaces' default-deny blocks Prometheus ingress → explicit 15090 ingress NetPols; `make observability` adds `monitoring` to namespace-exclusions.

### Bugs fixed
- Postgres init: official image entrypoint must run as root (drops to uid 999 via gosu); `runAsUser` broke `chmod`/`chown` on the PVC (`fsGroup: 999` only).
- `Job.spec.template` is immutable — Job manifest changes require delete + `argocd app sync --force`.
- istio sidecar breaks outbound TLS to external hosts in this kind setup (raw TCP passes, TLS EOF) — ingest Jobs run with `sidecar.istio.io/inject: "false"`.
- `aspnet:10.0` runtime image missing `libgssapi_krb5.so.2` (SslStream) — Dockerfile installs it (upstreamed).
- astronomy-api probes use `/health/ready` + `/health/live` (the code's actual health endpoints), not `/ready`.
- Private GHCR pulls failed 401: Skiperator builds the `github-auth` secret from `github-config`'s token placed verbatim into dockerconfigjson `auth`; since k8s `.data` is base64 the stored value must itself be `base64(user:token)` (double-encoded via kubectl).

### Tests
- Verified over HTTPS: `/health/ready` ready (db/kernels/starCatalog ok), sun position and star search return real ingested data, HPA scaling, ArgoCD Synced/Healthy.
