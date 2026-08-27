# apps/ — GitOps-managed applications

One directory per ArgoCD app (the ArgoCD `Application`s live in `argocd/apps/`).

## Per-app `meta.yaml` (drives the generic loop)

Each app directory carries a `meta.yaml` that drives the cloud-driven digest-bump
loop (`app-digest-bump.yml`), the PR gate (`validate.yml` `resolve-digest`/`gate-pr`)
and the onboarding scaffold (`make app-onboard`):

```yaml
app:
  name: <app>                          # short name; must match apps/<name>/ dir
  repo: <owner>/<repo>                 # app source repo; dispatch sender must match
  image: ghcr.io/<owner>/<image>       # image base name (digest is pinned in manifests)
  digestFiles:                         # manifests whose image digest must stay identical
    - apps/<name>/app.yaml
  hosts:                               # ingress hostnames (nip.io for local)
    - <name>.172.21.255.200.nip.io
  port: 8080                           # container port
  buildType: static | dotnet           # informational; the build lives in the app repo
  attestation: true | false            # true → SLSA gate + in-cluster admission policy
```

- `attestation: true` requires a **public** app repo (GitHub artifact attestations need
  public or Enterprise Cloud) and the repo's CI attesting inline in its own `ci.yml`
  (signer = `<repo>/.github/workflows/ci.yml@refs/heads/main`; the trust-policies chart
  validates at the organization level, `organization: toreau`).
- `attestation: false` skips the dispatch-time gate and in-cluster enforcement.

## Onboarding a new app

`make app-onboard NAME=<name> IMAGE=<full ref> HOST=<host> PORT=<port> [BUILD_TYPE=…] [ATTESTATION=…]`
generates the app dir, `meta.yaml` and the ArgoCD Application, then does the cluster
plumbing (namespace-exclusions, default-deny). Commit + push, then `make app-roll NAME=<name>`.
