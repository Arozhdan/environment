# Enterprise-style hardening checklist

Use this as a maturity ladder; not everything needs to be day one.

## Git

- **Branch protection** on `main`: require PRs, required status checks (`ci`), no force-push.
- **CODEOWNERS** for `bootstrap/` and `infra/` (optional).
- **Signed commits** (SSH or GPG) org-wide (optional).

## Argo CD

- **SSO** (OIDC) instead of local admin; rotate bootstrap admin password off.
- **AppProjects** separating `infra` vs `apps` with allowed cluster resources / destinations.
- **Notifications**: fill `notifications.notifiers` + `notifications.cm.templates` / `triggers` in `bootstrap/argocd/values.yaml`, store tokens in `notifications.secret.items` (Helm) or a sealed external secret.
- **RBAC**: map your IdP groups in `configs.rbac.policy.csv` (see comments in `bootstrap/argocd/values.yaml`).

## Cluster

- **Pod Security**: namespaces labeled for `restricted` where possible (`apps/hello` example).
- **NetworkPolicy**: default-deny per namespace where your CNI supports it; allow only from `ingress-nginx` (see `apps/hello/networkpolicy.yaml`).
- **Backups**: Velero (or provider snapshots) for etcd + PVs — especially before upgrades.
- **Upgrades**: pin k3s / addons; test in this staging cluster before managed prod.

## Observability

- **Grafana**: change `adminPassword`, move to `existingSecret`, expose via Tailscale or SSO.
- **Retention**: tune Prometheus / Loki retention and persistence (`infra/45-loki`).

## Renovate

- Enable the [Renovate app](https://github.com/apps/renovate) (or self-host) for this repo; tune `renovate.json` for automerge of patch bumps if desired.
