# cluster/attestations — Sigstore Policy Controller + GitHub trust-policies

Håndhever SLSA-attestasjoner ved admission for bildene i `policy.images` (referanseappen
`ghcr.io/toreau/frosta-historielag.no*`), i navnerom med label
`policy.sigstore.dev/include=true` (astronomy + frosta-historielag). Signer-valideringen er
**organisasjons-basert** (`organization: toreau`, `repository: '.*'`): enhver workflow i
toreau-orga (personlig konto = egne repoer) kan signere; per-app-provenance ligger i
attestasjons-SAN-en (hver app attesterer inline i egen `ci.yml`). Bootstrap: `make policy-controller`.

## Komponenter

- **policy-controller** (`oci://ghcr.io/sigstore/helm-charts/policy-controller`, v0.10.5) — admission-webhook.
- **trust-policies** (`oci://ghcr.io/github/artifact-attestations-helm-charts/trust-policies`, v0.7.0) — GitHub `TrustRoot` + `ClusterImagePolicy` (`github-policy`, `github-exempt-policy`).
- Verdier: `values-policy-controller.yaml` (chart-defaults), `values-trust-policies.yaml` (`organization`/`repository`, `images`, `exemptImages`).

## Gotcha-er (empiriske funn)

1. **Install-once:** re-`helm upgrade` på en eksisterende installasjon feiler — policy-controllerens
   Knative-reconciler eier webhook-`namespaceSelector`, og helm-apply konflikterer. `make policy-controller`
   installerer derfor kun om releasen er fraværende (`helm status … | grep 'STATUS: deployed' || helm upgrade --install`).
2. **`helm uninstall policy-controller` sletter `policy.sigstore.dev`-CRD-ene** (`trustroots`,
   `clusterimagepolicies`) — trust-policies-releasens `TrustRoot`/`CIP`-CR-er dør med dem og må reinstalleres.
3. **Org-basert vs `subjectRegExp`:** chartet støtter `policy.organization`+`policy.repository` for
   signer-validering (multi-app-klar) — foretrukket framfor `subjectRegExp` (single-signer, kun for
   reusable-workflow-signere). `subjectRegExp` krever `\\.` i verdifilen (chartet anfører dobbelt);
   org-basert krever ingen regex-escape.
4. **GitHub-autoriteten verifiserer (ennå) ikke våre bundles:** attestasjons-bundle-ene har
   rekor-tlog-entries, og GitHub-trust-roten krever egen tlog → «threshold not met for verified signed
   timestamps: 0 < 1». Håndhevingen kjører på `public-good`-autoriteten; behold `trust.sigstorePublic: true`
   (github-autoriteten er da harmless redundans).

## Endringer

- **Ny app som skal håndheves:** legg bildet til `policy.images` + label navnerommet
  `policy.sigstore.dev/include=true` + sørg for at app-repoet er **public** og attesterer inline i egen
  `ci.yml`. Re-apply med `make trust-policies-values`.
- **App som ikke skal håndheves (dempet):** utelat fra `policy.images` (eksempt; ingen admission-sjekk).
- **Ny signer-identitet** (f.eks. en app-repo renames): med org-basert policy kreves ingen `subjectRegExp`-endring
  (orga-kontoen dekker alle egne repoer). Ved bruk av `subjectRegExp`: oppdater + `make trust-policies-values`.

## Relatert

- Negativ test: uattestert bilde nektes med «no valid bundles exist in registry» (fail-closed).
- Uten `imagePullSecrets` → `UNAUTHORIZED`: controlleren autentiserer mot private registries via
  pod-ens pull-secrets (f.eks. `github-auth` fra Skiperator).
