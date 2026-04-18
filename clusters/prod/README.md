# Production cluster (dry-run / future managed VPC)

This directory is a **scaffold** for a second cluster (e.g. managed Kubernetes in a cloud VPC). Nothing here is wired into the staging `ApplicationSet` flows yet.

## Promotion model

- **Shared**: `infra/*` and `apps/*` stay the single source of truth.
- **Different per cluster**: only values/overlays under `clusters/<name>/overrides/` (or separate branches) should diverge — for example:
  - LoadBalancer / NodePort / internal-only Services
  - Higher replicas, PDBs, HPAs
  - Stricter `NetworkPolicy`, `PodDisruptionBudget`, resource quotas
  - Different `ClusterIssuer` (e.g. private CA or DNS-01 in cloud DNS)

## Suggested next step

When the prod cluster exists:

1. Register the cluster in Argo CD (`argocd cluster add` or declarative secret).
2. Duplicate `clusters/homelab-staging/appset-*.yaml` with a new name and:
   - `spec.template.spec.destination.name` (or server URL) for prod
   - Optional `spec.template.spec.source.targetRevision` / branch
3. Keep **Git** as the promotion mechanism: merge to `main` → staging syncs; tag or promote revision → prod syncs (manual or automated).

See `overrides/README.md` for example override ideas.
