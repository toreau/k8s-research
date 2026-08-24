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
- [ ] Phase 1 — `make setup-local` (cluster + Istio + cert-manager + Skiperator CRDs)
- [ ] Phase 2 — `make run-operator` (host binary) + sample Application
- [ ] Phase 3 — MetalLB + nip.io + ClusterIssuer (HTTPS end-to-end)
- [ ] Phase 4 — ArgoCD + local git (git daemon) GitOps loop
- [ ] Phase 5 — polish (local registry, Routing/SKIPJob demos, k9s)

See `AGENTS.md` for stack details, key commands, and gotchas.
