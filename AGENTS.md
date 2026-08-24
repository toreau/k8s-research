# AGENTS.md — k8s-research

Local Kubernetes testing stack on a MacBook Pro (arm64 / macOS 26). Stack:
**kind** + **Skiperator** (Kartverket operator) + **ArgoCD** (GitOps).

Precedence: this file applies to this repo; global `~/.config/opencode/AGENTS.md`
still governs memory/search routing and mutation policy.

## Stack facts

- Skiperator is NOT standalone: it assumes a service-mesh platform and generates
  Istio `VirtualService`/`Gateway`/`Sidecar`/`PeerAuthentication`, cert-manager
  `Certificate`, `NetworkPolicy`, HPA/PDB, and Prometheus `ServiceMonitor` from a
  small `Application` (v1alpha1) CR. Also `Routing` and `SKIPJob` (v1beta1) CRDs.
- Latest release: v2.18.0. Source: `github.com/kartverket/skiperator`.
- The repo's own dev setup IS kind-based: `make setup-local` creates a kind
  cluster `kind-skiperator` (kindest/node **v1.34.3**) and installs all deps.
  `make run-local` builds and runs the operator as a host binary with the webhook
  tunneled into the cluster (port 9443).
- Version pins for Istio / cert-manager / gateway-api / prometheus come from
  Skiperator's `go.mod` at clone time (Makefile `extract-version`).

## Key commands (wrapped in repo `Makefile`)

```bash
make cluster          # skiperator: make setup-local  (Phase 1)
make run-operator     # skiperator: make run-local    (Phase 2)
make cluster-delete   # kind delete cluster --name skiperator
make verify           # print tool versions
```

## Gotchas

- **UID 150**: Skiperator hardcodes the app container user id 150 — test images
  must be built with `USER 150` (repo `samples/` shows the pattern).
- **Config ConfigMaps**: reconcilers depend on `skiperator-config`,
  `docker-config`, `github-config` ConfigMaps; `make setup-local` applies them.
- **ClusterIssuer**: ingress hostnames get cert-manager certs — a ClusterIssuer
  must exist (self-signed CA for local; name aligned with `config/skiperator-config.yaml`).
- **LoadBalancer**: kind has none — MetalLB provides IPs (Phase 3); use `*.nip.io`
  hostnames. External gateway svc `istio-ingress-external` pinned to `172.21.255.200`.
- **External ingress gateway (Phase 3)**: Skiperator's ingress Gateways select
  `app: istio-ingress-external` in `istio-gateways` — that workload must be provisioned
  (see `cluster/istio-gateways/`). It needs `ISTIO_META_CLUSTER_ID=Kubernetes` and a
  ClusterRoleBinding letting its SA read secrets, or istiod refuses to serve app certs
  ("attempted to access unauthorized certificates").
- **App cert secrets**: Skiperator creates certs in `istio-gateways`; the per-app Gateway's
  `credentialName` resolves in the app namespace → copy the TLS secret (tls.crt/tls.key/ca.crt)
  into the app namespace after each reconcile.
- **Docker Desktop routing**: the host CANNOT reach the kind bridge subnet (172.21.0.0/16).
  Use `kubectl port-forward -n istio-gateways svc/istio-ingress-external 8443:443` and
  `curl --cacert ... --connect-to host:443:127.0.0.1:8443`.
- **HTTPS testing**: SNI comes from the URL hostname, not the `Host:` header — use
  `--resolve`/`--connect-to`, else envoy resets (no filter chain for the IP SNI).
- **metrics-server**: needs `--kubelet-insecure-tls --cert-dir=/tmp --secure-port=10250`
  (probes hit the named port `https`=10250; read-only root FS needs `--cert-dir=/tmp`).
- **sample-two port quirk**: upstream sample declares port 80, but nginx-unprivileged listens
  on 8080 — local copy uses `port: 8080`.
- **Local-only git for ArgoCD**: kind reaches the host via `host.docker.internal`;
  serve the repo with `git daemon` on `127.0.0.1:9418` (unauthenticated — loopback only).
- The Skiperator clone lives at `./skiperator` and is git-ignored (own repo).
- This Mac: 64 GiB RAM / 18 CPUs; Docker Desktop allocated 32 GiB (no bump needed).

## Conventions

- `apps/` = what ArgoCD manages; `cluster/` = applied directly (kubectl).
- Don't commit secrets (ArgoCD admin password etc.) — read from cluster, note paths.
- Work logs go to Docmost `Work Logs/`; durable stack docs to Docmost.
