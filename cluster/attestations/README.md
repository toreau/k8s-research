# cluster/attestations — Sigstore Policy Controller + GitHub trust-policies

Håndhever SLSA-attestasjoner ved admission for bildene i `policy.images` (referanseappen
`ghcr.io/toreau/frosta-historielag.no**`), i navnerom med label
`policy.sigstore.dev/include=true`. Referanseappen frosta-historielag er enforced;
astronomy er damped (ikke labelt, ikke admission-enforced). Signer-identiteten er
avgrenset til trusted central reusable `container-build-attest`-workflowen; tillatte
signer-revisjoner følger det kanoniske promotion-trustsettet i `ci/trusted-builders.yaml`
(konsistens håndhevet av `ci/scripts/admission-trust.rb`). Bootstrap: `make policy-controller`.

## Komponenter

- **policy-controller** (`oci://ghcr.io/sigstore/helm-charts/policy-controller`, v0.10.5) — admission-webhook.
- **trust-policies** (`oci://ghcr.io/github/artifact-attestations-helm-charts/trust-policies`, v0.7.0) — GitHub `TrustRoot` + `ClusterImagePolicy` (`github-policy`, `github-exempt-policy`).
- Verdier: `values-policy-controller.yaml` (chart-defaults), `values-trust-policies.yaml` (`subjectRegExp`, `images`, `exemptImages`).

## Gotcha-er (empiriske funn)

1. **Install-once:** re-`helm upgrade` på en eksisterende installasjon feiler — policy-controllerens
   Knative-reconciler eier webhook-`namespaceSelector`, og helm-apply konflikterer. `make policy-controller`
   installerer derfor kun om releasen er fraværende (`helm status … | grep 'STATUS: deployed' || helm upgrade --install`).
2. **`helm uninstall policy-controller` sletter `policy.sigstore.dev`-CRD-ene** (`trustroots`,
   `clusterimagepolicies`) — trust-policies-releasens `TrustRoot`/`CIP`-CR-er dør med dem og må reinstalleres.
3. **Signer-validering med `subjectRegExp`:** fordi signeren er en reusable workflow, bruker
   vi `policy.subjectRegExp` (ikke `organization`/`repository`). Literale punktum skrives som
   `[.]`-karakterklasser (ingen backslash-escaping). Builder-revisjonsrotasjon styres via det
   kanoniske trusted-builder-settet + matching `subjectRegExp`, guarded av `admission-trust`.
4. **GitHub-autoriteten verifiserer (ennå) ikke våre bundles:** attestasjons-bundle-ene har
   rekor-tlog-entries, og GitHub-trust-roten krever egen tlog → «threshold not met for verified signed
   timestamps: 0 < 1». Håndhevingen kjører på `public-good`-autoriteten; behold `trust.sigstorePublic: true`
   (github-autoriteten er da harmless redundans).

## Endringer

- **Ny app som skal håndheves:** krev eksplisitt beslutning om image-scope + namespace-label
  `policy.sigstore.dev/include=true` + en produsent som er kompatibel med trusted-builder-policyen
  (provenance via central `container-build-attest`, ikke app-local signing). `attestation: true`
  alene aktiverer IKKE admission. Re-apply med `make trust-policies-values`.
- **App som ikke skal håndheves (dempet):** utelat fra `policy.images` (eksempt; ingen admission-sjekk).
- **Ny signer-identitet / builder-revisjonsrotasjon:** endres kun gjennom det kanoniske
  trusted-builder-settet (`ci/trusted-builders.yaml`) med tilsvarende `subjectRegExp`-oppdatering;
  `admission-trust` blokkerer uenighet. Re-apply med `make trust-policies-values`.

## Relatert

- Negativ test: uattestert bilde nektes med «no valid bundles exist in registry» (fail-closed).
- Uten `imagePullSecrets` → `UNAUTHORIZED`: controlleren autentiserer mot private registries via
  pod-ens pull-secrets (f.eks. `github-auth` fra Skiperator).
