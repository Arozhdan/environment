# Workstation prerequisites

Install on the machine you use to manage Git and `kubectl`:

| Tool | Purpose |
|------|---------|
| `git` | Clone / push this repo |
| `kubectl` | Talk to the cluster (via kubeconfig) |
| `helm` | `helm lint`, and local `kustomize build --enable-helm` |
| `kustomize` | Optional; `kubectl` bundles a compatible version |
| `argocd` CLI | Login, app sync, debugging |
| `age` + `sops` | Encrypt secrets committed to Git |
| `pre-commit` | Hooks before `git commit` |
| `kubeconform` | Local CI parity with `.github/workflows/ci.yaml` |

## Connectivity

- **Tailscale**: ensure `kubectl get nodes` works from your laptop against the k3s API (often `~/.kube/config` with the mini PC’s Tailscale IP or MagicDNS name).
- **Git host**: GitHub/GitLab/etc. must be reachable from the cluster so Argo CD can clone this repo (or use a private git mirror / deploy key).

## Quick checks

```bash
kubectl version --client
kubectl get nodes
kubectl -n argocd get pods
```
