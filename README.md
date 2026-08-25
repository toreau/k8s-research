# k8s-research

Local Kubernetes testing stack on a MacBook Pro (Apple Silicon / arm64):

- **kind** — throwaway local cluster (`kind-skiperator`, k8s 1.34.3)
- **Skiperator** — Kartverket's operator (Application / Routing / SKIPJob CRs)
- **ArgoCD** — GitOps delivery for the Skiperator manifests (local-only git source)

> Dette dokumentet dekker fase 0–5-oppbyggingen. Gjeldende struktur (7-app-app-of-apps,
> observability-plattform, astronomy-demo) og alle kommandoer: se `AGENTS.md`.

## Layout

```
apps/      ArgoCD-managed manifests, one directory per ArgoCD app (sample/, astronomy/, observability/, tools/)
argocd/    ArgoCD helm values + root Application manifest (k8s-apps.yaml → argocd/apps/ 6 Applications)
cluster/   Platform manifests applied directly (kind config, MetalLB, cert-manager issuer)
```

## Phase status

- [x] Phase 0 — tooling + workspace (this repo)
- [x] Phase 1 — `make setup-local` (cluster + Istio + cert-manager + Skiperator CRDs)
- [x] Phase 2 — `make run-operator` (host binary) + sample Application
- [x] Phase 3 — MetalLB + nip.io + ClusterIssuer (HTTPS end-to-end)
- [x] Phase 4 — ArgoCD + local git (git daemon) GitOps loop
- [x] Phase 5 — polish (UID-150 test app, Routing demo, cron SKIPJob, HPA, k9s, Makefile helpers)

## Phase 5 notes (verified)

- **UID-150 test app** (`testapp/`, Go, `USER 150`): built + pushed to GHCR (`make testapp-image`);
  `apps/sample/hello.yaml` (HPA min2/max4 @cpu50) runs 2/2 with **real HPA targets** (`kubectl get hpa hello`).
- **Routing demo**: `apps/sample/routing.yaml` (`routing.172.21.255.200.nip.io`) → `/` serves sample-two (nginx),
  `/api` serves hello (rewriteUri) — both HTTPS with the local CA. Cert secret re-copied into `sample`.
- **Cron SKIPJob**: `apps/sample/skipjob-cron.yaml` → CronJob `sample-job-cron` (suspended via GitOps).
- **`enableLocallyBuiltImages: false`** (default in `skiperator-config`, clone's `config/skiperator-config.yaml`)
  → Skiperator resolves image→digest against the registry; **all apps are registry-backed** (GHCR digest-pins,
  `github-auth` imagePullSecret); no `kind load` needed. (The flag was `true` during Phase 5 with
  `imagePullPolicy: Never`; since Fase 1 everything is registry-pulled.)
- **Makefile helpers**: `make operator/operator-stop`, `serve-git/git-stop`, `pf/pf-stop`, `status`, `argo-sync`.
- **k9s** 0.51.0 installed.

## Phase 4 notes (verified)

- **ArgoCD** 10.4.0 (app v3.5.1) via helm; UI at http://127.0.0.1:8081 (port-forward; admin pw in
  `/tmp/argocd-admin.txt`). **App-of-apps**: root Application `argocd/k8s-apps.yaml` (path `argocd/apps`)
  manages 6 Applications (astronomy, prometheus-platform, observability-base, grafana, cert-sync,
  sample-apps) from `git://host.docker.internal:9418/k8s-research` (auto-sync + self-heal + prune).
- **git daemon** serves this working repo on 127.0.0.1:9418 (background, restart manually).
- **GitOps loop proven**: commit `apps/sample/sample-two.yaml` replicas 2→3 → `make argo-sync` → deployment
  3/3; manual drift on the Skiperator CR → self-heal reverted it.
- **Gotcha**: Skiperator's namespace controller applies `default-deny` NetworkPolicies (Ingress+Egress)
  to every non-excluded namespace. ArgoCD (not istio-injected) was broken until `argocd`,
  `metallb-system`, `local-path-storage` were added to the `namespace-exclusions` ConfigMap and the
  stale default-deny NetPols deleted.
- **Gotcha**: `kubectl get application` now resolves to the ArgoCD kind — use the full
  `applications.skiperator.kartverket.no` for Skiperator CRs.
- ArgoCD manages the Skiperator CRs, not the operator-generated Deployment — self-heal applies at CR level.

## Phase 3 notes (verified)

- **External ingress gateway**: Skiperator's ingress Gateways select `app: istio-ingress-external`
  (in `istio-gateways`) — that workload isn't part of a default istio install. Provisioned via
  `cluster/istio-gateways/ingress-external-deploy.yaml` (+ support/RBAC). Must set
  `ISTIO_META_CLUSTER_ID=Kubernetes` and grant the gateway SA `get/list/watch` secrets
  (cluster-scoped) or istiod won't serve the certs via SDS.
- **Cert secrets**: Skiperator puts app certs in `istio-gateways`, but the per-app Gateway's
  `credentialName` resolves in the app namespace — copy the TLS secret (incl. `ca.crt`) there.
- **MetalLB**: pool `172.21.255.200-250` (kind subnet); external gateway svc pinned to
  `172.21.255.200` via `metallb.io/loadBalancerIPs`. Old istio-ingressgateway moved to `.201`.
- **Docker Desktop can't route to the kind bridge subnet** — the host reaches the LB IP via
  `kubectl port-forward -n istio-gateways svc/istio-ingress-external 8443:443`. TLS verified
  with `curl --cacert` + `--connect-to` and `openssl s_client` (issuer = local CA, chain OK).
- **HTTPS test gotcha**: SNI comes from the URL host — use `--resolve`/`--connect-to`, not `-H Host:`.
- **sample-two**: upstream sample declares `port: 80` but nginx-unprivileged listens on 8080 →
  patched to `port: 8080`. sample-one stays Pending by design (dummy PVC/UID 150).
- **metrics-server**: v0.9.0 needs `--kubelet-insecure-tls --cert-dir=/tmp --secure-port=10250`
  (probes target the named `https` port 10250).

See `AGENTS.md` for stack details, key commands, and gotchas.
