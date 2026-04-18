# environment — GitOps definition for the homelab (staging) cluster

Single **source of truth** for Kubernetes: **Argo CD** pulls this repo; changes land via **PR → merge**, not ad-hoc `kubectl apply` (except one-time bootstrap).

## Architecture

| Layer | Choice |
|-------|--------|
| Cluster | **k3s** (you already run it) |
| GitOps | **Argo CD** + **ApplicationSet** (directory generator) |
| Layout | `infra/*` = platform, `apps/*` = workloads — each folder is **Kustomize** (+ **Helm** charts inflated by Kustomize) |
| Ingress / TLS | **ingress-nginx** + **cert-manager** + **Let's Encrypt HTTP-01** (no cloud-specific Issuer config) |
| Edge | **cloudflared** only — maps public hostnames to `ingress-nginx` inside the cluster |
| Secrets | **SOPS + age** → **`sops-secrets-operator`** via `secrets/*` GitOps apps (see `docs/secrets.md`) |
| Observability | **kube-prometheus-stack**, **Loki**, **Grafana Alloy** |

**Traditional networking**: everything except `infra/30-cloudflared` is standard Kubernetes Ingress/Service resources, portable to a future managed prod cluster.

## Repo layout

```text
bootstrap/argocd/      # Argo CD Helm values + one-shot bootstrap manifests
clusters/homelab-staging/   # ApplicationSet definitions (canonical)
clusters/prod/         # Scaffold / docs for a future prod cluster
infra/                 # Platform (ordered by numeric prefixes)
apps/                  # Applications
secrets/               # One dir per encrypted secret app (SOPS) — see docs/secrets.md
docs/                  # Runbooks
```

## Prerequisites

See **`docs/PREREQS.md`**. You need `kubectl` (via Tailscale to the mini PC), `helm`, `kustomize` (or `kubectl` with kustomize), and tools for local validation (`kubeconform`).

## Configure Git remote placeholders

Replace every `https://github.com/CHANGE_ME/environment.git` with the exact repo URL you register in Argo CD (HTTPS or SSH, and branch if not `main`):

- `bootstrap/argocd/install.yaml` — `Application` for Argo CD (`ref: values` source)
- `clusters/homelab-staging/appset-*.yaml`
- `bootstrap/argocd/root-appset.yaml` (duplicate of the cluster ApplicationSets above for convenience)

## One-time bootstrap

With **Argo CD already installed** on the cluster:

```bash
# 1) Let Argo CD manage itself from Git (Helm chart + values in-repo)
kubectl apply -f bootstrap/argocd/install.yaml

# 2) Register ApplicationSets (same content as clusters/homelab-staging/)
kubectl apply -f bootstrap/argocd/root-appset.yaml
# or: kubectl apply -k clusters/homelab-staging/
```

Then **register the Git repository** in Argo CD using the same URL scheme you put into those manifests. If Argo is configured with an SSH repo, the `repoURL` values here must also be SSH.

For the first bring-up, treat it as a short staged rollout:

1. Bootstrap Argo CD and let the infra apps reconcile.
2. Create the in-cluster age key Secret for `sops-secrets-operator` in `sops-system`.
3. Wait until `infra-10-cert-manager`, `infra-20-ingress-nginx`, and `infra-28-sops-secrets-operator` are healthy.
4. Add `secrets/<app>/` encrypted secret apps.
5. Let dependent workloads such as `cloudflared` settle once their secrets exist.

## End-to-end smoke test

1. Edit **`infra/30-cloudflared/config.yaml`**: set `tunnel:` UUID and `hostname:` entries to match DNS.
2. Create **`secrets/cloudflared/`** with a `kustomization.yaml` and an encrypted `SopsSecret` that materializes `cloudflared-credentials` in the `cloudflared` namespace (see `docs/secrets.md`).
3. Set **ACME email** in `infra/10-cert-manager/clusterissuers.yaml`.
4. Replace **`hello.example.com`** in `apps/hello/ingress.yaml` and align tunnel hostname + DNS.
5. Sync apps — browse `https://hello.<your-domain>` and confirm a **staging** Let’s Encrypt cert (`letsencrypt-staging` Issuer by default).

On a first sync, some apps may briefly show as progressing while their dependencies come up. Hard dependencies that must be ordered together are co-located in the same app (`cert-manager` + `ClusterIssuer`, Alloy + `observability` namespace), and encrypted secret apps should only be added after `sops-secrets-operator` is healthy.

## CI & local validation

```bash
bash scripts/check-sops.sh
bash scripts/validate.sh   # needs helm + kustomize + kubeconform
make helm-lint-argocd
```

GitHub Actions runs **`ci`** (kustomize/kubeconform + yamllint + helm lint for Argo CD).

## Hardening & prod

- **`docs/hardening.md`** — SSO, backups, policies, Renovate.
- **`docs/branch-protection.md`** — GitHub branch protection.
- **`clusters/prod/`** — how to think about a second cluster without duplicating bases.

## Renovate

Enable [Renovate](https://github.com/apps/renovate) for automated dependency PRs; config: **`renovate.json`**.
