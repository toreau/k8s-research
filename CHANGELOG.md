# Changelog

## 2026-08-26 (reusable workflow library: toreau/gh-workflows)

### Infrastructure & ops
- **New reusable workflow library `toreau/gh-workflows`** (public, tag `v1`): 8 reusable workflows — `manifest-validate`, `dotnet-ci`, `container-build-push`, `container-merge-attest` (outputs `digest`), `dispatch`, `attestation-gate`, `digest-bump`, `native-pin-watcher`. This repo's `validate.yml` and `astro-digest-bump.yml` are rewritten as **thin callers** pinned `@v1` (PR #2/#3/#4); behavior unchanged. Cross-repo refs pinned by tag; dependabot (github-actions ecosystem) tracks `@v1`.
- **Verified**: `validate` green against `@v1`; `astro-digest-bump` gate **fails** on an unattested digest (no commit) and is a no-op on the current digest. Full E2E re-check with the astronomy migration (Fase 2). `toreau/gh-workflows` hosting chosen because GitHub does not allow **public** caller → **private** callee reusable workflows (same-owner private→private only).

## 2026-08-26 (CI hardening: actions by SHA + dependabot)

### Infrastructure & ops
- **GitHub Actions pinned by SHA** (supply-chain hardening): `actions/checkout` now referenced by commit SHA (tag kept as `# v4` comment) in `validate.yml` and `astro-digest-bump.yml`. New `.github/dependabot.yml` with the `github-actions` ecosystem (weekly, grouped) so action bumps arrive as reviewable PRs: **PR #1 (checkout v4.4.0 → 7.0.1) was reviewed and merged** (`8fe4d6a`), `validate` green. `79bec91`.

## 2026-08-25 (docs audit: k8s-research + astronomy)

### Documentation
- Full documentation audit of k8s-research + astronomy.aursand.no (ground-truth snapshot, 52-doc inventory, claim-for-claim verification, gap report). Fixes (Docmost): corrected `namespace-exclusions` list (Projects gotcha #5 + k8s manual §7/§13: 11 values incl. `kyverno`; `local-path-storage`/`metallb-system` are NOT excluded), added `cluster/kyverno/`, Kyverno version and `make kyverno` to Projects, added a «SLSA / Kyverno» section to Decisions & gotchas, linked `Projects/k8s-research` from the canonical Projects index, refreshed Services/astronomy (commit `7437db6`, SLSA/CI, degraded-registry reality), host-server (48/48 containers, disk 34 %) and Services/coolify (4.3.10). Astronomy repo: README/AGENTS/API.md/live-verification refreshed (commit `42d1c09`).
- **Prod finding (RESOLVED, 2026-08-25):** the astronomy prod dataset registry is fully repopulated: **5/5 datasets active**. `naif-kernels` re-staged eop-c04/leap-seconds/star-catalog-hyg and `omm-refresh` activated satellite-elements `20260825` after the sat-gate thresholds were relaxed (epoch ≤72 h, |bstar| ≤0.03); `naif` and `omm-refresh` no longer core-dump on upstream failures (astronomy `48bcffb`/`a18c4a4`); naif task timeout 300 → 1800 s. `eop-ut1` is now active via the **IERS Bulletin A fallback** (USNO ser7 was serving an implausible UT1-UTC 8.0 s; astronomy `ef43fbc`). Detail: `Work Logs/2026-08-25 k8s-research + astronomy docs audit: gap report`.

## 2026-08-25 (SLSA-5: E2E + docs)

### Infrastructure & ops
- **End-to-end verified** the full cloud-driven, SLSA-hardened loop with a real astronomy push (`7437db6`): CI multi-arch build + attestation (SLSA-1) → `astro-image-pushed` dispatch → digest-bump **gate** verified the attestation (SLSA-3) → bump commit `a4abbf6` → ArgoCD auto-synced → **Kyverno `ImageValidatingPolicy` admitted** the new pod (SLSA-4) → `astronomy-verify` ALL OK. Negative re-check: an unattested image pod is denied at admission.
- **`make kyverno`** idempotent bootstrap target: patches `namespace-exclusions`, deletes the stale default-deny NetPol, `helm install` Kyverno (if absent), creates `regcred` (if absent, needs `GHCR_TOKEN`), applies `cluster/kyverno/require-astronomy-attestation.yaml`.
- README gained a «SLSA supply-chain» section (producer attest → consumer gate → in-cluster Kyverno).

## 2026-08-25 (SLSA-4: Kyverno in-cluster attestation enforcement)

### Infrastructure & ops
- **Kyverno (v1.19.0, helm chart 3.9.0) installed in `kind`** (`cluster/kyverno/`, applied directly): `kyverno` added to `namespace-exclusions` (Skiperator default-deny gotcha), `existingImagePullSecrets: [regcred]` renders the controller's `--imagePullSecrets`, and a **`Namespaced`-scoped `ImageValidatingPolicy`** (the current Aug-2026 type; legacy `ClusterPolicy` `verifyImages` is deprecated, removal in v1.20) requires a SLSA-provenance attestation on every `ghcr.io/toreau/astronomy-api*` image via CEL `verifyAttestationSignatures` + cosign keyless (subject `…/ci.yml@refs/heads/main`, issuer `https://token.actions.githubusercontent.com`, ctlog `rekor.sigstore.dev`). Registry auth for the private GHCR package via `credentials.secrets: [regcred]` (docker-registry secret in the kyverno ns, token created outside git).
- Verified positive (attested image admitted; `rollout restart astronomy-api` → new pod Running) and negative (pod with the unattested old digest denied at admission, never created).
- **Learning:** the legacy `verifyImages` + `type: SigstoreBundle` path fails on GitHub artifact attestations in v1.19 (`sigstore bundle verification failed: no matching signatures found`) even with correct identities; the `ImageValidatingPolicy` CEL path verifies them. Also: cosign v3 finds these attestations via OCI referrers (v2 does not).

## 2026-08-25 (SLSA-3: digest-bump verification gate)

### Infrastructure & ops
- **`astro-digest-bump.yml` verifies the SLSA attestation before committing** the digest bump: it queries `GET /repos/{owner}/{repo}/attestations/{sha256:<digest>}` (GitHub attestations REST API: **no registry auth needed**) and requires ≥1 attestation including the `https://slsa.dev/provenance/v1` predicate. A digest without an attestation fails the job → **no commit**. Full signature verification already runs producer-side in the astronomy CI (SLSA-1); in-cluster cosign enforcement is SLSA-4.
- **Learned:** `gh attestation verify oci://ghcr.io/toreau/astronomy-api@…` requires GHCR credentials for the private astronomy package (the `oci://` resolution hits the registry), even though the attestation itself lives in the public repo's attestations API, hence the REST-based gate.
- Verified positive (attested `aa1ace8e` passes; no-op since already pinned) and negative (unattested `0d0cae` blocked, `api.yaml` unchanged).

## 2026-08-25 (Documentation refresh: Del A–E)

### Documentation
- `README.md` rewritten as a clean current-state doc (GitHub ArgoCD source, cloud-driven multi-arch loop, arm64 cluster, no git daemon/local build/watcher): `f170e04`.
- Docmost `Projects/k8s-research` main page rewritten current-state (Del 1–4 notes folded in): GitHub source + token, cloud-driven loop, fresh-cluster gotchas, updated astronomy table.
- Docmost `Projects/k8s-research/Decisions & gotchas` updated: repo-server behind **GitHub**-HEAD, multi-arch CI flow, new fresh-cluster subsection, `sha256:`-prefix digest trap, GITHUB_TOKEN no-CI-loop.
- Docmost Norwegian k8s manual updated throughout: git daemon → GitHub source (`argocd repo add`), GitOps loop = commit+push, `make operator pf`, astronomy image via cloud-driven loop, new «Fase 8: sky-drevet bilde-løkke», fresh-cluster gotchas.
- Final sweep clean: the only repo matches for legacy terms are the intentional "No local git daemon" statements; legacy references survive only in historical work logs / this changelog.
- New consolidated work log: Docmost `Work Logs/2026-08-25 k8s-research documentation refresh (Del A–E)`.

## 2026-08-25 (Del 4: Mac-local image tooling removed)

### Infrastructure & ops
- **Local astronomy auto-update watcher removed entirely**: `scripts/astronomy-auto-update.sh`, the launchd agent (`no.aursand.astronomy-auto-update.plist` + template), the `make astronomy-auto-update*` targets and the `.astro-update/` state directory are deleted; the installed launchd plist is uninstalled. The image loop is fully cloud-driven (Del 3): push → CI multi-arch → dispatch → digest bump → ArgoCD auto-sync.
- **`make astronomy-image` removed** (local arm64 build + multi-arch merge): CI does the multi-arch build/merge now. Unused `ASTRONOMY_DIR`/`ASTRONOMY_IMAGE` Makefile vars dropped; `ghcr-login`/`testapp-image` kept. `make status` no longer tracks a watcher.
- After Del 4 the Mac only participates in the demo loop as the kind-cluster host (cluster, operator, port-forwards): no local build or GitOps-side process.

## 2026-08-25 (Del 3: cloud-driven multi-arch image loop)

### Core
- **Fully cloud-driven astronomy image loop** (no Mac involvement): push to `astronomy.aursand.no` `main` → CI builds **multi-arch** (matrix amd64 `ubuntu-latest` + arm64 `ubuntu-24.04-arm`, an arm64 hosted runner confirmed available) → `merge` job combines the manifest (`main-<sha>`, `latest`) via `buildx imagetools create` → resolves the manifest digest → dispatches `astro-image-pushed` (`{sha, digest}`) to k8s-research → new `astro-digest-bump.yml` workflow bumps the digest in `apps/astronomy/api.yaml` (only that file) → ArgoCD auto-syncs from GitHub → Skiperator rolls the cluster. Cross-repo auth: `K8S_RESEARCH_PAT` secret in the astronomy repo (dispatch; currently the `gh auth token`); bump commits push with GITHUB_TOKEN (no CI re-trigger).
- The astronomy CI is no longer amd64-only; per-arch tags (`main-<sha>-{amd64,arm64}`, `latest-{amd64,arm64}`) plus merged multi-arch tags are pushed. The Dockerfile was already multi-arch-ready (cspice `-m64` patch).
- `make astronomy-image` (local arm64 build + merge) and the local auto-update watcher are now **obsolete** and scheduled for removal in Del 4.

### Bugs fixed
- `astro-digest-bump.yml` double-prefixed the digest: `imagetools inspect --format '{{.Manifest.Digest}}'` returns `sha256:<hex>` while the sed capture group already included `sha256:` → `api.yaml` got `sha256:sha256:…`. Fixed by stripping the `sha256:` prefix from the payload digest before substitution; the malformed `api.yaml` (commit `c171279`) was corrected in `eb3bca6`.

## 2026-08-25 (Del 1–2: cloud-driven GitOps)

### Infrastructure & ops
- **ArgoCD sources GitHub directly**: `repoURL` flipped from the local git daemon (`git://host.docker.internal:9418/k8s-research`) to `https://github.com/toreau/k8s-research.git` in all 7 Applications; the git daemon is retired (`make serve-git`/`git-stop` removed, AGENTS.md rewritten). Verified GitHub→ArgoCD auto-sync in both directions with zero local action (no git daemon). Fresh clusters now need `argocd repo add ... --password <token>` (private repo; token in `argocd-repo-secret`).
- **Cluster rebuilt as arm64 (native)**: amd64-kind is blocked on Apple Silicon: containerd reports `seccomp is not supported` for every static pod under both QEMU and Rosetta (Rosetta already enabled + VM restarted). The image pipeline therefore needs multi-arch CI (matrix amd64+arm64 + merge) instead of amd64-only.
- `sample` namespace is now GitOps-managed (`apps/sample/namespace.yaml`); fresh clusters lacked it, so `sample-apps` sync failed.
- Istio gateway cert RBAC is now a **cluster-scoped** ClusterRole/ClusterRoleBinding (`gateway-cert-reader`); the old sample-only Role made SDS never deliver the gateway TLS secrets.

### Bugs fixed
- Fresh-cluster gotchas (reproducible on every `kind delete` + rebuild): Skiperator's namespace controller default-denies new namespaces (`argocd`, `monitoring`) before they reach `namespace-exclusions`: delete the stale `default-deny` NetPol after patching the ConfigMap. MetalLB hands `172.21.255.200` to the default `istio-system/istio-ingressgateway` first: patch it to ClusterIP so the custom `istio-gateways/istio-ingress-external` gets the IP.
- `/tmp/local-ca.crt` is cluster-specific and must be re-extracted after a rebuild (kubectl jsonpath needs an escaped dot: `{.data.ca\.crt}`); a stale CA makes `astronomy-verify` fail with "unable to get local issuer certificate".
- `astronomy-api` caches kernel/catalog state at startup; after ingest completes, the Deployment must be restarted before `/health/ready` reports `kernels/starCatalog: ok`.
- NAIF/JPL hosts (`naif.jpl.nasa.gov`, `ssd.jpl.nasa.gov`) were unreachable during ingest (also from the host); base kernels (`naif0012.tls`, `pck00010.tpc`) were fetched from the reachable GitHub mirror `arturania/cspice` into the PVC hostPath.

## 2026-08-25

### Infrastructure & ops
- ArgoCD **app-of-apps (flat, 7 apps)**: root `k8s-apps` (path `argocd/apps/`) manages 6 Applications: `astronomy` (the demo: api + `db/` postgres + `infra/` ns/PVC/netpols + `ingest/` 3 Jobs; path `apps/astronomy`, recursive), `prometheus-platform` (Prometheus operator + Prometheus + istiod/envoy scrapes; path `apps/observability/platform`), `observability-base` (monitoring ns), `grafana`, `cert-sync`, `sample-apps`. `make argo-sync` syncs all in dependency order; `make status` lists every app. (Iterated during the day via 11 per-component apps → 14 with nested groups → merged to the final 7 to declutter the Applications list.)
- Observability as a **shared, app-agnostic platform**: envoy PodMonitor + istiod ServiceMonitor in `prometheus-platform` scrape any istio-injected namespace; per-app onboarding = ServiceMonitor/PodMonitor labeled `app.kubernetes.io/name: observability` + a TCP 15090 ingress NetPol in the app namespace (pattern in `apps/observability/README.md` and AGENTS.md).
- Repo layout grouped per ArgoCD app (`apps/sample/`, `apps/astronomy/{api.yaml,db/,infra/,ingest/}`, `apps/observability/{base,platform,grafana}/`, `apps/tools/`); migrations done with zero workload deletions (ArgoCD resource ownership moved via tracking annotations).
- CI (`validate.yml`) now also runs kubeconform + yamllint over `argocd/apps/`.
- **Astronomy auto-update**: local watcher (`scripts/astronomy-auto-update.sh`) that polls the astronomy repo's `main`, builds the arm64 image + merges the multi-arch manifest, bumps the digest in `apps/astronomy/` (api + ingest Jobs), commits and syncs ArgoCD: `make astronomy-auto-update{-loop,-stop,-plist}` (launchd for reboot persistence). CI stays amd64-only (multi-arch-via-QEMU in CI was rejected as too slow).

### Bugs fixed
- `make observability` checked `deploy/prometheus-operator` in `monitoring`, but the operator Deployment/SA live in `default` (per manifest); the rollout gate always failed. Now checks `-n default`.
- Envoy `PodMonitor` scraped the same pod **3×** (one target per container: app/istio-init/istio-proxy, all mapped to pod IP:15090). Added a `keep` relabeling on `__meta_kubernetes_pod_container_name = istio-proxy`: one target per sidecar pod (target count per mesh pod 3→1, verified via onboarding demo).

## 2026-08-24

### Core
- Local Kubernetes testing stack: kind `skiperator` (k8s 1.34.3) + Skiperator + ArgoCD GitOps.
- Astronomy demo: `astronomy.aursand.no` also deployed into the local stack (same repo/image, two environments): dedicated Postgres, SPICE-kernel + dataset ingest, Skiperator Application with HPA and HTTPS on `astronomy.172.21.255.200.nip.io`.
- Reproducible demo: `make astronomy` bootstraps secrets, syncs ArgoCD, waits for Postgres + ingest Jobs, copies the TLS cert and smoke-verifies; idempotent after `make cluster-delete` → `make cluster`.
- Astronomy image runs as **UID 150** (matches Skiperator's enforced securityContext; prod on Coolify now runs as 150).

### Infrastructure & ops
- **CI: `kubeconform` + `yamllint` over `apps/`** (`.github/workflows/validate.yml`) with Skiperator CRD schemas committed under `ci/schemas/`; istio/monitoring CRs ignored.

### Infrastructure & ops
- ArgoCD `k8s-apps` root Application made cluster-wide and recursive (`source.directory.recurse`) so `apps/` subdirectories are synced.
- GitOps-managed Postgres (`apps/astronomy-db/`) and astronomy namespace (`apps/astronomy/`) with default-deny + explicit egress/ingress NetworkPolicies.
- Data ingest as plain `batch/v1` Jobs (sidecar-free); Skiperator `SKIPJob` forces `PullAlways`, incompatible with local images.
- One artifact, two environments: astronomy Dockerfile made multi-arch and upstreamed; CI pushes `ghcr.io/toreau/astronomy-api` (amd64), local `make astronomy-image` builds arm64 and merges the multi-arch manifest; `enableLocallyBuiltImages` off: all apps registry-backed (GHCR digest-pins, `github-auth` imagePullSecret wired from `github-config` auth blob).
- `cert-sync` CronJob (`apps/tools/`) in the `default` namespace (exempt from default-deny, so it can reach the kube-apiserver) re-copies the app TLS secret from `istio-gateways` into `astronomy` on a schedule; RBAC `get`+`list` on certificates (label selectors require `list`).
- Observability (`apps/observability/`): upstream prometheus-operator v0.93.1 (matches the setup-local CRDs), minimal `Prometheus` CR (SA + ClusterRole for k8s service discovery), ServiceMonitor for istiod (15014) and PodMonitor for envoy sidecars (15090 via pod-IP relabel; the merged 15020 isn't reachable from the pod IP), Grafana with the three istio dashboards (provisioned ConfigMaps). Gotchas: dashboards ConfigMap was too large for ArgoCD's last-applied annotation (split into 3); app namespaces' default-deny blocks Prometheus ingress → explicit 15090 ingress NetPols; `make observability` adds `monitoring` to namespace-exclusions.

### Bugs fixed
- Postgres init: official image entrypoint must run as root (drops to uid 999 via gosu); `runAsUser` broke `chmod`/`chown` on the PVC (`fsGroup: 999` only).
- `Job.spec.template` is immutable: Job manifest changes require delete + `argocd app sync --force`.
- istio sidecar breaks outbound TLS to external hosts in this kind setup (raw TCP passes, TLS EOF); ingest Jobs run with `sidecar.istio.io/inject: "false"`.
- `aspnet:10.0` runtime image missing `libgssapi_krb5.so.2` (SslStream): Dockerfile installs it (upstreamed).
- astronomy-api probes use `/health/ready` + `/health/live` (the code's actual health endpoints), not `/ready`.
- Private GHCR pulls failed 401: Skiperator builds the `github-auth` secret from `github-config`'s token placed verbatim into dockerconfigjson `auth`; since k8s `.data` is base64 the stored value must itself be `base64(user:token)` (double-encoded via kubectl).

### Tests
- Verified over HTTPS: `/health/ready` ready (db/kernels/starCatalog ok), sun position and star search return real ingested data, HPA scaling, ArgoCD Synced/Healthy.
