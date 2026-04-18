# Encrypted secrets

- Put each secret app in its own subdirectory, for example `secrets/cloudflared/`.
- Only **SOPS-encrypted** manifests belong here, plus the minimal `kustomization.yaml` files that reference them. Other plaintext YAML is blocked by `scripts/check-sops.sh` and CI.
- Follow `docs/secrets.md` to generate an **age** key and configure `.sops.yaml`.
- Use `SopsSecret` manifests here so the `homelab-staging-secrets` ApplicationSet can reconcile them like any other GitOps app.
- Keep real tunnel credentials out of `infra/`; `infra/30-cloudflared/secret.example.yaml` is documentation only and is never applied.
