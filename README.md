# k8s-research

Local Kubernetes testing stack on a MacBook Pro (Apple Silicon / arm64 / macOS): **kind** + **Skiperator** (Kartverket's operator) + **ArgoCD** (GitOps). The cluster is a throwaway local environment, and the deployment loop is **fully cloud-driven**; the Mac only hosts the cluster, the operator and port-forwards.

Full detail, key commands and gotchas: **`AGENTS.md`**. Build history: Docmost `Work Logs/2026-08-24 Phase 0` … `2026-08-25 Del 1–4` and the repo `CHANGELOG.md`.

## Architecture

```
astronomy.aursand.no (git) ──CI (multi-arch matrix + manifest merge)──► GHCR
        │ 2. dispatch astro-image-pushed {sha, digest}
        ▼
k8s-research (git, GitHub) ──astro-digest-bump.yml──► digest bump in apps/astronomy/api.yaml
        │ ArgoCD (auto-sync + self-heal); source = GitHub (private, token)
        ▼
kind cluster (arm64) → Skiperator CRs → operator (host binary) → k8s resources
```

- Cluster `kind-skiperator` (k8s **1.34.3**, single node, native **arm64**).
- Istio **1.30.3** (istiod + custom external ingress gateway), cert-manager **1.21.1** (local CA), MetalLB **0.16.1** (external LB `172.21.255.200`), ArgoCD **10.4.0** (helm), metrics-server **0.9.0**, Skiperator **v2.18.0** (host binary).
- ArgoCD is **app-of-apps**: root `k8s-apps` (path `argocd/apps`) manages 6 Applications: `astronomy`, `prometheus-platform`, `observability-base`, `grafana`, `cert-sync`, `sample-apps` (7 apps total). Source is the **private GitHub repo** `toreau/k8s-research` (token in `argocd-repo-secret`, added via `argocd repo add`). No local git daemon.
- **Astronomy image loop (cloud-driven)**: push to `astronomy.aursand.no` `main` → CI builds **multi-arch** (amd64 + arm64 matrix) → merges the manifest (`main-<sha>`, `latest`) → dispatches `astro-image-pushed` `{sha, digest}` → `astro-digest-bump.yml` bumps the digest in `apps/astronomy/api.yaml` (only that file) → ArgoCD auto-syncs from GitHub → the cluster rolls. No Mac involvement beyond hosting the cluster.

## Repo layout

- `apps/`: GitOps-managed, one directory per ArgoCD app (`sample/`, `astronomy/{api.yaml,db/,infra/,ingest/}`, `observability/{base,platform,grafana}/`, `tools/`)
- `argocd/`: helm values + root Application `k8s-apps.yaml` + `apps/*.yaml` (6 Applications)
- `cluster/`: applied directly: `metallb/`, `istio-gateways/`, `metrics-server/`, `attestations/` (Sigstore Policy Controller + GitHub trust-policies)
- `testapp/`: UID-150 Go test app
- `.github/workflows/`: `validate.yml` (kubeconform + yamllint) + `astro-digest-bump.yml` (cloud-driven digest bump)

## SLSA supply-chain

The astronomy image loop is SLSA-hardened at three layers (all verified end-to-end):
1. **Producer (astronomy CI):** the merged multi-arch image is attested with SLSA build provenance + an SPDX SBOM (`actions/attest`, `push-to-registry`), and verified before dispatch.
2. **Consumer gate (k8s-research `astro-digest-bump.yml`):** a digest is only committed if the GitHub attestations API returns a valid SLSA provenance for it.
3. **In-cluster (Sigstore Policy Controller + GitHub `trust-policies`, `cluster/attestations/`):** a pod running an unattested `ghcr.io/toreau/astronomy-api*` image is denied at admission (`ClusterImagePolicy`, cosign keyless; bootstrap with `make policy-controller`).

> **Verification split:** the consumer gate is a *lightweight* check: it verifies only that an attestation exists with an SLSA-provenance predicate (keeping unattested digests out of git). Cryptographic signature verification happens **producer-side** (`gh attestation verify` in the astronomy CI, at build time) and **in-cluster** (Sigstore Policy Controller, fail-closed at admission).

> **Lær flyten:** [`docs/explained.md`](docs/explained.md): norsk, pedagogisk gjennomgang av hele kjeden (git push → CI → attestasjon → gate → ArgoCD → Policy Controller → rollout), skrevet for utviklere uten DevOps-bakgrunn.

## Quick start

```bash
make status        # cluster + processes + all 7 ArgoCD apps (start here)
make operator      # Skiperator operator host binary (log /tmp/skiperator-operator.log); operator-stop
make pf            # port-forwards: ArgoCD 8081, istio HTTPS 8443; pf-stop
make argo-sync     # sync all ArgoCD apps (root + 6, in order)
make cluster       # fresh kind cluster + platform (skiperator: make setup-local)
make astronomy     # bootstrap the astronomy demo end-to-end (idempotent); astronomy-verify
make observability # Prometheus + Grafana (monitoring ns); pf-grafana
```

- ArgoCD UI: http://127.0.0.1:8081 · admin pw: `/tmp/argocd-admin.txt`
- HTTPS test: `curl --cacert /tmp/local-ca.crt --connect-to <host>:443:127.0.0.1:8443 https://<host>/` (CA from `cert-manager/local-test-ca`)
- **GitOps change**: edit `apps/*` → commit **and push** → ArgoCD auto-syncs (or `make argo-sync` for an immediate manual sync).
- **Fresh cluster**: `make cluster` → install ArgoCD (helm, `argocd/values.yaml`) → `argocd repo add https://github.com/toreau/k8s-research.git --username toreau --password <token>` (private repo) → `kubectl apply -f argocd/k8s-apps.yaml` → `make astronomy`.

## Verification cheat-sheet

```bash
make status
make argo-sync
make astronomy-verify      # demo smoke-test (fail-fast)
kubectl -n argocd get applications   # 7 apps Synced/Healthy
curl --cacert /tmp/local-ca.crt --connect-to sample-two.172.21.255.200.nip.io:443:127.0.0.1:8443 https://sample-two.172.21.255.200.nip.io/
```

See `AGENTS.md` for the full command list, workflows, onboarding and gotchas; Docmost (`Projects/k8s-research`, the Norwegian k8s manual, work logs) for durable knowledge and build history.
