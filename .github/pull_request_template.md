## Summary

<!-- What does this PR change? -->

## Risk / rollout

<!-- Infra vs app? Any manual steps? -->

## Checklist

- [ ] `make validate` (or CI green) — kustomize + kubeconform
- [ ] No plaintext secrets under `secrets/` (only `*.enc.yaml` with SOPS)
- [ ] If touching Helm pins: chart changelog skimmed
