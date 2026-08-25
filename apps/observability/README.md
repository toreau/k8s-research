# Observability — delt plattform

Prometheus + Grafana er en **delt, app-agnostisk plattform** i `monitoring`-navnerommet.
Alle ArgoCD-apper her er generiske (base/operator/prometheus/scrapes/grafana) — ingen
er bundet til en bestemt applikasjon.

## Slik onboards en ny app

1. Legg appens manifests i en egen ArgoCD-app (se `argocd/apps/`).
2. **Sidecar-metrikker (envoy):** skrapes automatisk for alle istio-injiserte pods
   (`prometheus-scrapes`/envoy-PodMonitor matcher `service.istio.io/canonical-name`
   klynge-vidt). App-navnerommet må imidlertid tillate inngående 15090 fra
   `monitoring` — default-deny (Skiperator) blokkerer ellers. Legg til en NetPol:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-prometheus-envoy
     namespace: <app-namespace>
   spec:
     podSelector: {}
     policyTypes: [Ingress]
     ingress:
       - from:
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: monitoring
         ports: [{protocol: TCP, port: 15090}]
   ```
   (Se `apps/astronomy-infra/allow-prometheus-envoy.yaml` og `apps/sample/allow-prometheus-envoy.yaml`.)
3. **App-egne metrikker** (`/metrics`): legg til en ServiceMonitor/PodMonitor med
   label **`app.kubernetes.io/name: observability`** i app-navnerommet — da skrapes den
   av `prometheus`. Tilsvarende NetPol for metrikk-porten hvis navnerommet er default-denied.
4. **Dashboards:** provisionert ConfigMap under `apps/observability/grafana/dashboards/`,
   eller via Grafana-UI.

`istiod`-kontrollplansmetrikker dekkes av `prometheus-scrapes`/istiod-ServiceMonitor.
