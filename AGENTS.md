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
  hostnames.
- **Local-only git for ArgoCD**: kind reaches the host via `host.docker.internal`;
  serve the repo with `git daemon` on `127.0.0.1:9418` (unauthenticated — loopback only).
- The Skiperator clone lives at `./skiperator` and is git-ignored (own repo).
- This Mac: 64 GiB RAM / 18 CPUs; Docker Desktop allocated 32 GiB (no bump needed).

## Conventions

- `apps/` = what ArgoCD manages; `cluster/` = applied directly (kubectl).
- Don't commit secrets (ArgoCD admin password etc.) — read from cluster, note paths.
- Work logs go to Docmost `Work Logs/`; durable stack docs to Docmost.
