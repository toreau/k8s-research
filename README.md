# k8s-research

Local Kubernetes testing stack on a MacBook Pro (Apple Silicon / arm64 / macOS): **kind** + **Skiperator** (Kartverket's operator) + **ArgoCD** (GitOps). The cluster is a throwaway local environment, and the deployment loop is **fully cloud-driven**; the Mac only hosts the cluster, the operator and port-forwards.

## Architecture

```
app repo (git) ──CI (trusted central builder)──► GHCR (arm64, attested + provenance)
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
- **Generic app loop (cloud-driven)**: any app rides the loop via `apps/<app>/meta.yaml` (repo, image, digestFiles, hosts, port, buildType, attestation). The app repo's CI invokes the trusted central reusable builder (`container-build-attest.yml`, accepted revision set in `ci/trusted-builders.yaml`), which builds the single **arm64** image (`main-<sha>`), generates SLSA provenance + SBOM, and returns the digest; the app CI then dispatches `app-image-pushed` `{app, sha, digest}` → `app-digest-bump.yml` applies the consumer policy (`attestation: true` = strong provenance authorization; `attestation: false` = damped image-to-digest binding; neither enables Kubernetes admission) and **opens a PR** (`bump/<app>-{sha7}`) → PR checks (`validate-apps`, `validate-argocd`, `gate-pr`) → **manual review + merge** (ruleset-protected) → ArgoCD auto-syncs from GitHub → the cluster rolls. The **reference app** (attested + in-cluster enforced) is config-driven (`values-trust-policies.yaml`); astronomy rides the same loop, damped. No Mac involvement beyond hosting the cluster. Bump PRs have two human touchpoints: approve the bot's workflow runs, then review + merge.

## Repo layout

- `apps/`: GitOps-managed, one directory per ArgoCD app (`sample/`, `astronomy/{api.yaml,db/,infra/,ingest/}`, `observability/{base,platform,grafana}/`, `tools/`)
- `argocd/`: helm values + root Application `k8s-apps.yaml` + `apps/*.yaml` (7 Applications)
- `cluster/`: applied directly: `metallb/`, `istio-gateways/`, `metrics-server/`, `attestations/` (Sigstore Policy Controller + GitHub trust-policies)
- `testapp/`: UID-150 Go test app
- `.github/workflows/`: `validate.yml` (kubeconform + yamllint + `gate-pr` digest gate) + `app-digest-bump.yml` (cloud-driven digest bump via PR, driven by `apps/<app>/meta.yaml`)
- `scripts/`: `protect-main.sh` (ruleset-based protection of main: PRs + validate-apps/validate-argocd/gate-pr checks, no direct push, admin PR-only bypass; `make protect-main`)

## SLSA supply-chain

The app image loop is SLSA-hardened at three layers (all verified end-to-end):
1. **Producer (app CI invokes the trusted central builder):** the trusted reusable `container-build-attest.yml` workflow (accepted revision set in `ci/trusted-builders.yaml`) validates the exact caller source/build configuration (`.github/container-build.json`), builds the image, generates an SPDX SBOM, generates SLSA provenance, and returns the digest. Provenance is designed for and assessed as compatible with SLSA Build L3, with no formal conformance assessment performed (SLSA v1.2 Build L3 semantics). Provenance does not by itself prove that approved source code or build logic is non-malicious; source-control governance is a separate boundary.
2. **Consumer gate (k8s-research `app-digest-bump.yml` + `validate.yml` `gate-pr`):** attested apps (attestation: true) are authorized through a strong provenance path: before the bump PR is opened the gate verifies the expected image/digest binding, cryptographic provenance, the exact trusted signer workflow, an accepted signer revision, source-ref and the source-digest of the dispatched producer commit; the required `gate-pr` check re-verifies the digest selected by the PR, requires the trusted signer workflow and an accepted revision with source-ref `refs/heads/main`, and intentionally does not require one fixed source-digest, so final promotion can roll back to another artifact produced from trusted main. Damped apps (attestation: false) use the damped image-to-digest binding policy instead of provenance-based authorization.
3. **In-cluster (Sigstore Policy Controller + GitHub `trust-policies`, `cluster/attestations/`):** admission is explicit and separately configured: image scope `ghcr.io/toreau/frosta-historielag.no**` in the enforced namespace `frosta-historielag`, signed by the trusted central `container-build-attest` workflow at an accepted revision (anchored `policy.subjectRegExp`, synchronized with `ci/trusted-builders.yaml` via `ci/scripts/admission-trust.rb`). `attestation: true` alone does not enable Kubernetes admission; admission requires an explicit image scope, namespace enforcement, and trusted-builder-compatible provenance.

> **Verification split:** the promotion consumer cryptographically verifies provenance, signer identity and accepted signer revision, with stronger source constraints; Kubernetes admission enforces signer/revision and the SLSA provenance predicate for the explicitly scoped reference image. The two are related trust boundaries but do not evaluate identical fields.

## Quick start

```bash
make status        # cluster + processes + all 8 ArgoCD Application resources (start here)
make operator      # Skiperator operator host binary (log /tmp/skiperator-operator.log); operator-stop
make pf            # port-forwards: ArgoCD 8081, istio HTTPS 8443; pf-stop
make argo-sync     # sync root + 6 child Applications, astronomy excluded
make cluster       # fresh kind cluster + platform (skiperator: make setup-local)
make astronomy     # bootstrap the astronomy demo end-to-end (idempotent); astronomy-verify
make observability # Prometheus + Grafana (monitoring ns); pf-grafana
make protect-main  # ruleset on main: PR + checks, no direct push, admin PR-only bypass
```

- ArgoCD UI: http://127.0.0.1:8081 · admin pw: `/tmp/argocd-admin.txt`
- HTTPS test: `curl --cacert /tmp/local-ca.crt --connect-to <host>:443:127.0.0.1:8443 https://<host>/` (CA from `cert-manager/local-test-ca`)
- **GitOps change**: edit `apps/*` → push a branch + open a PR (**main is ruleset-protected**: required checks `validate-apps`/`validate-argocd`/`gate-pr` + 1 review; direct push to main is blocked for everyone; in the single-owner case the approving-review requirement may be the sole remaining unsatisfied condition after all required checks PASS, and the explicitly authorized pull-request ruleset bypass may then be exercised) → ArgoCD auto-syncs (or `make argo-sync` for an immediate manual sync).
- **Fresh cluster**: `make cluster` → install ArgoCD (helm, `argocd/values.yaml`) → `argocd repo add https://github.com/toreau/k8s-research.git --username toreau --password <token>` (repo is **public**; token optional but kept) → `kubectl apply -f argocd/k8s-apps.yaml` → `make astronomy`.

## Verification cheat-sheet

```bash
make status
make argo-sync
make astronomy-verify      # demo smoke-test (fail-fast)
kubectl -n argocd get applications   # 8 Application resources Synced/Healthy
curl --cacert /tmp/local-ca.crt --connect-to sample-two.172.21.255.200.nip.io:443:127.0.0.1:8443 https://sample-two.172.21.255.200.nip.io/
```
