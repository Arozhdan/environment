# `infra/` — platform components

Directories use numeric prefixes for readability and coarse sync-wave hints (`10-*`, `20-*`, etc.). Any hard dependency that must come up together is kept inside the same app.

| Prefix | Component | Notes |
|--------|-----------|--------|
| `10-cert-manager` | ACME / certificates | CRDs + controller |
| `20-ingress-nginx` | Ingress controller | “Traditional” in-cluster HTTP routing |
| `28-sops-secrets-operator` | SOPS → Secrets | For encrypted Git secrets |
| `30-cloudflared` | Cloudflare Tunnel | **Only** edge component; swap for LB in cloud prod |
| `40-kube-prometheus-stack` | Prometheus + Grafana | Metrics |
| `45-loki` | Loki | Logs |
| `46-alloy` | Grafana Alloy | Ship pod logs to Loki |

`ClusterIssuer` manifests live inside `10-cert-manager/` so CRDs and issuers reconcile in the same app. The `observability` namespace is also present in both Loki- and Alloy-related apps so initial sync does not depend on cross-Application ordering.

The SOPS operator expects an in-cluster Secret named `sops-age` in the `sops-system` namespace; see `infra/28-sops-secrets-operator/age-key-secret.example.yaml` and `docs/secrets.md`.

Each subdirectory is a **Kustomize** overlay that may inflate **Helm** charts (`helmCharts` in `kustomization.yaml`). Argo CD is configured with `kustomize.buildOptions: --enable-helm` in `bootstrap/argocd/values.yaml`.
