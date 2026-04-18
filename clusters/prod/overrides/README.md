# Example per-cluster overrides (not applied automatically)

Use **Kustomize patches** or **Helm value files** referenced from an ApplicationSet template when you add a second cluster.

Examples:

- **`hello` Ingress host + TLS**: change `hello.prod.example.com` vs `hello.staging.example.com`.
- **`ClusterIssuer`**: staging might use `letsencrypt-staging`; prod uses `letsencrypt-prod`.
- **`cloudflared`**: omit in prod if you terminate TLS on a cloud LB instead of a tunnel.
- **Resource limits**: increase `apps/hello` replicas in prod; add `PodDisruptionBudget`.

Pattern:

```text
clusters/prod/overrides/
  hello/
    ingress-patch.yaml
    kustomization.yaml   # references apps/hello base from repo root via remote base or copy
```

For GitOps, prefer **no copy-paste**: point Argo CD `source.path` at `apps/hello` and add a **small overlay directory** in this repo, e.g. `clusters/prod/apps/hello-overlay/`, that uses `resources` + `patches` against the shared base.
