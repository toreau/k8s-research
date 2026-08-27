# k8s-research

Local Kubernetes testing stack on a MacBook Pro (Apple Silicon / arm64 / macOS): **kind** + **Skiperator** (Kartverket's operator) + **ArgoCD** (GitOps). The cluster is a throwaway local environment, and the deployment loop is **fully cloud-driven**; the Mac only hosts the cluster, the operator and port-forwards.

## Architecture

```
app repo (git) ──CI (single arch + inline SLSA attest)──► GHCR (arm64, attested)
        │ 2. dispatch app-image-pushed {app, sha, digest}
        ▼
k8s-research (git, GitHub) ──app-digest-bump.yml──► opens PR (gate → PR checks → review → merge)
        │ ArgoCD (auto-sync + self-heal); source = GitHub (public; token in argocd-repo-secret)
        ▼
kind cluster (arm64) → Skiperator CRs → operator (host binary) → k8s resources
```

- Cluster `kind-skiperator` (k8s **1.34.3**, single node, native **arm64**).
- Istio **1.30.3** (istiod + custom external ingress gateway), cert-manager **1.21.1** (local CA), MetalLB **0.16.1** (external LB `172.21.255.200`), ArgoCD **10.4.0** (helm), metrics-server **0.9.0**, Skiperator **v2.18.0** (host binary).
- ArgoCD is **app-of-apps**: root `k8s-apps` (path `argocd/apps`) manages 7 Applications: `astronomy`, `prometheus-platform`, `observability-base`, `grafana`, `cert-sync`, `sample-apps`, `frosta-historielag` (8 apps total). Source is the **public GitHub repo** `toreau/k8s-research` (token in `argocd-repo-secret` is technically optional now, kept for compatibility; added via `argocd repo add`). No local git daemon.
- **Generic app loop (cloud-driven)**: any app rides the loop via `apps/<app>/meta.yaml` (repo, image, digestFiles, hosts, port, buildType, attestation). The app repo's CI builds a single **arm64** image and attests it inline in its own `ci.yml` (`main-<sha>`, `latest`), then dispatches `app-image-pushed` `{app, sha, digest}` → `app-digest-bump.yml` reads the app's meta (gates the digest only when `attestation: true`) and **opens a PR** (`bump/<app>-{sha7}`) → PR checks (`validate-apps`, `validate-argocd`, `gate-pr`) → **manual review + merge** (branch protection) → ArgoCD auto-syncs from GitHub → the cluster rolls. Reference app: `frosta-historielag` (attested + in-cluster enforced); astronomy rides the same loop, damped. No Mac involvement beyond hosting the cluster. Bump PRs have two human touchpoints: approve the bot's workflow runs, then review + merge.

## Repo layout

- `apps/`: GitOps-managed, one directory per ArgoCD app (`sample/`, `astronomy/{api.yaml,db/,infra/,ingest/}`, `observability/{base,platform,grafana}/`, `tools/`)
- `argocd/`: helm values + root Application `k8s-apps.yaml` + `apps/*.yaml` (6 Applications)
- `cluster/`: applied directly: `metallb/`, `istio-gateways/`, `metrics-server/`, `attestations/` (Sigstore Policy Controller + GitHub trust-policies)
- `testapp/`: UID-150 Go test app
- `.github/workflows/`: `validate.yml` (kubeconform + yamllint + `gate-pr` digest gate) + `astro-digest-bump.yml` (cloud-driven digest bump via PR)
- `scripts/`: `protect-main.sh` (branch protection on main; `make protect-main`)

## SLSA supply-chain

The astronomy image loop is SLSA-hardened at three layers (all verified end-to-end):
1. **Producer (astronomy CI):** the merged multi-arch image is attested with SLSA build provenance + an SPDX SBOM (`actions/attest`, `push-to-registry`), and verified before dispatch.
2. **Consumer gate (k8s-research `astro-digest-bump.yml` + `validate.yml` `gate-pr`):** an unattested digest never lands — the gate runs fail-fast before the PR is opened, and again as a required `gate-pr` PR check (the GitHub attestations API must return a valid SLSA provenance for the digest).
3. **In-cluster (Sigstore Policy Controller + GitHub `trust-policies`, `cluster/attestations/`):** a pod running an unattested `ghcr.io/toreau/astronomy-api*` image is denied at admission (`ClusterImagePolicy`, cosign keyless; bootstrap with `make policy-controller`).

> **Verification split:** the consumer gate is a *lightweight* check: it verifies only that an attestation exists with an SLSA-provenance predicate (keeping unattested digests out of git). Cryptographic signature verification happens **producer-side** (`gh attestation verify` in the astronomy CI, at build time) and **in-cluster** (Sigstore Policy Controller, fail-closed at admission).

## Quick start

```bash
make status        # cluster + processes + all 7 ArgoCD apps (start here)
make operator      # Skiperator operator host binary (log /tmp/skiperator-operator.log); operator-stop
make pf            # port-forwards: ArgoCD 8081, istio HTTPS 8443; pf-stop
make argo-sync     # sync all ArgoCD apps (root + 6, in order)
make cluster       # fresh kind cluster + platform (skiperator: make setup-local)
make astronomy     # bootstrap the astronomy demo end-to-end (idempotent); astronomy-verify
make observability # Prometheus + Grafana (monitoring ns); pf-grafana
make protect-main  # branch protection on main (required checks + 1 review)
```

- ArgoCD UI: http://127.0.0.1:8081 · admin pw: `/tmp/argocd-admin.txt`
- HTTPS test: `curl --cacert /tmp/local-ca.crt --connect-to <host>:443:127.0.0.1:8443 https://<host>/` (CA from `cert-manager/local-test-ca`)
- **GitOps change**: edit `apps/*` → push a branch + open a PR (**main is branch-protected**: required checks `validate-apps`/`validate-argocd`/`gate-pr` + 1 review; a single-user repo can't self-review, so merge with `gh pr merge --admin` or push directly as admin) → ArgoCD auto-syncs (or `make argo-sync` for an immediate manual sync).
- **Fresh cluster**: `make cluster` → install ArgoCD (helm, `argocd/values.yaml`) → `argocd repo add https://github.com/toreau/k8s-research.git --username toreau --password <token>` (repo is **public**; token optional but kept) → `kubectl apply -f argocd/k8s-apps.yaml` → `make astronomy`.

## Verification cheat-sheet

```bash
make status
make argo-sync
make astronomy-verify      # demo smoke-test (fail-fast)
kubectl -n argocd get applications   # 7 apps Synced/Healthy
curl --cacert /tmp/local-ca.crt --connect-to sample-two.172.21.255.200.nip.io:443:127.0.0.1:8443 https://sample-two.172.21.255.200.nip.io/
```
