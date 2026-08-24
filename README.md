# k8s-research

Local Kubernetes testing stack on a MacBook Pro (Apple Silicon / arm64):

- **kind** — throwaway local cluster (`kind-skiperator`, k8s 1.34.3)
- **Skiperator** — Kartverket's operator (Application / Routing / SKIPJob CRs)
- **ArgoCD** — GitOps delivery for the Skiperator manifests (local-only git source)

## Layout

```
apps/      ArgoCD-managed Skiperator manifests (Application/Routing/SKIPJob) — Phase 4 source
argocd/    ArgoCD helm values + root Application manifest
cluster/   Platform manifests applied directly (kind config, MetalLB, cert-manager issuer)
```

## Phase status

- [x] Phase 0 — tooling + workspace (this repo)
- [x] Phase 1 — `make setup-local` (cluster + Istio + cert-manager + Skiperator CRDs)
- [x] Phase 2 — `make run-operator` (host binary) + sample Application
- [x] Phase 3 — MetalLB + nip.io + ClusterIssuer (HTTPS end-to-end)
- [ ] Phase 4 — ArgoCD + local git (git daemon) GitOps loop
- [ ] Phase 5 — polish (local registry, Routing/SKIPJob demos, k9s)

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
