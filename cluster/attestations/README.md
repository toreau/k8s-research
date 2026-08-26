# cluster/attestations — Sigstore Policy Controller + GitHub trust-policies

Håndhever SLSA-attestasjoner ved admission for `ghcr.io/toreau/astronomy-api*`-bilder
i namespace-et `astronomy` (label `policy.sigstore.dev/include=true`), verifisert mot
GitHub-artifact-attestasjoner signert av astronomy-`ci.yml`-workflow-en
(`toreau/astronomy.aursand.no`). Bootstrap: `make policy-controller`.

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
3. **`subjectRegExp` i verdifilen skrives med `\\.`** (dobbel backslash): chartet renderer verdien
   dobbelt-anført (`| quote`), så `\.` er ugyldig YAML-escape; `\\.` gir enkelt backslash i JSON
   (literal dot i regex-et).
4. **GitHub-autoriteten verifiserer (ennå) ikke våre bundles:** attestasjons-bundle-ene har
   rekor-tlog-entries, og GitHub-trust-roten krever egen tlog → «threshold not met for verified signed
   timestamps: 0 < 1». Håndhevingen kjører på `public-good`-autoriteten; behold `trust.sigstorePublic: true`
   (github-autoriteten er da harmless redundans).

## Endringer

- **Nytt bilde i astronomy-ns:** legg det til `policy.exemptImages` (hvis det ikke skal attest-verifiseres),
  eller sørg for at det er attestet hvis det matcher `policy.images`.
- **Ny signer-identitet** (f.eks. astronomy-`ci.yml` renames/flyttes, eller tag-bump): oppdater
  `subjectRegExp` og re-apply med `make trust-policies-values` (eksplisitt `helm upgrade trust-policies`,
  u-gated — konflikten på webhook-`namespaceSelector` gjelder kun policy-controller-releasen). Uninstall
  + reinstall trengs kun ved CRD-død (se gotcha 2).

## Relatert

- Negativ test: uattestert bilde nektes med «no valid bundles exist in registry» (fail-closed).
- Uten `imagePullSecrets` → `UNAUTHORIZED`: controlleren autentiserer mot private registries via
  pod-ens pull-secrets (f.eks. `github-auth` fra Skiperator).
