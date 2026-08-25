# Changelog

## 2026-08-25 (Del 1–2 — cloud-driven GitOps)

### Infrastructure & ops
- **ArgoCD sources GitHub directly**: `repoURL` flipped from the local git daemon (`git://host.docker.internal:9418/k8s-research`) to `https://github.com/toreau/k8s-research.git` in all 7 Applications; the git daemon is retired (`make serve-git`/`git-stop` removed, AGENTS.md rewritten). Verified GitHub→ArgoCD auto-sync in both directions with zero local action (no git daemon). Fresh clusters now need `argocd repo add ... --password <token>` (private repo; token in `argocd-repo-secret`).
- **Cluster rebuilt as arm64 (native)**: amd64-kind is blocked on Apple Silicon — containerd reports `seccomp is not supported` for every static pod under both QEMU and Rosetta (Rosetta already enabled + VM restarted). The image pipeline therefore needs multi-arch CI (matrix amd64+arm64 + merge) instead of amd64-only.
- `sample` namespace is now GitOps-managed (`apps/sample/namespace.yaml`) — fresh clusters lacked it, so `sample-apps` sync failed.
- Istio gateway cert RBAC is now a **cluster-scoped** ClusterRole/ClusterRoleBinding (`gateway-cert-reader`) — the old sample-only Role made SDS never deliver the gateway TLS secrets.

### Bugs fixed
- Fresh-cluster gotchas (reproducible on every `kind delete` + rebuild): Skiperator's namespace controller default-denies new namespaces (`argocd`, `monitoring`) before they reach `namespace-exclusions` — delete the stale `default-deny` NetPol after patching the ConfigMap. MetalLB hands `172.21.255.200` to the default `istio-system/istio-ingressgateway` first — patch it to ClusterIP so the custom `istio-gateways/istio-ingress-external` gets the IP.
- `/tmp/local-ca.crt` is cluster-specific and must be re-extracted after a rebuild (kubectl jsonpath needs an escaped dot: `{.data.ca\.crt}`); a stale CA makes `astronomy-verify` fail with "unable to get local issuer certificate".
- `astronomy-api` caches kernel/catalog state at startup — after ingest completes, the Deployment must be restarted before `/health/ready` reports `kernels/starCatalog: ok`.
- NAIF/JPL hosts (`naif.jpl.nasa.gov`, `ssd.jpl.nasa.gov`) were unreachable during ingest (also from the host); base kernels (`naif0012.tls`, `pck00010.tpc`) were fetched from the reachable GitHub mirror `arturania/cspice` into the PVC hostPath.

## 2026-08-25

### Infrastructure & ops
- ArgoCD **app-of-apps (flat, 7 apps)**: root `k8s-apps` (path `argocd/apps/`) manages 6 Applications — `astronomy` (the demo: api + `db/` postgres + `infra/` ns/PVC/netpols + `ingest/` 3 Jobs; path `apps/astronomy`, recursive), `prometheus-platform` (Prometheus operator + Prometheus + istiod/envoy scrapes; path `apps/observability/platform`), `observability-base` (monitoring ns), `grafana`, `cert-sync`, `sample-apps`. `make argo-sync` syncs all in dependency order; `make status` lists every app. (Iterated during the day via 11 per-component apps → 14 with nested groups → merged to the final 7 to declutter the Applications list.)
- Observability as a **shared, app-agnostic platform**: envoy PodMonitor + istiod ServiceMonitor in `prometheus-platform` scrape any istio-injected namespace; per-app onboarding = ServiceMonitor/PodMonitor labeled `app.kubernetes.io/name: observability` + a TCP 15090 ingress NetPol in the app namespace (pattern in `apps/observability/README.md` and AGENTS.md).
- Repo layout grouped per ArgoCD app (`apps/sample/`, `apps/astronomy/{api.yaml,db/,infra/,ingest/}`, `apps/observability/{base,platform,grafana}/`, `apps/tools/`); migrations done with zero workload deletions (ArgoCD resource ownership moved via tracking annotations).
- CI (`validate.yml`) now also runs kubeconform + yamllint over `argocd/apps/`.
- **Astronomy auto-update**: local watcher (`scripts/astronomy-auto-update.sh`) that polls the astronomy repo's `main`, builds the arm64 image + merges the multi-arch manifest, bumps the digest in `apps/astronomy/` (api + ingest Jobs), commits and syncs ArgoCD — `make astronomy-auto-update{-loop,-stop,-plist}` (launchd for reboot persistence). CI stays amd64-only (multi-arch-via-QEMU in CI was rejected as too slow).

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
