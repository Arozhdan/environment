# actions-runner-controller v2 — first-time bootstrap

Sets up self-hosted GitHub Actions runners on the homelab cluster. Workloads
that label `runs-on: opshot-runners` get an ephemeral pod per job; idle = zero
compute.

Layout (already wired into Argo CD via the existing ApplicationSets):

```
infra/35-arc-controller/         # cluster-wide operator (chart: gha-runner-scale-set-controller)
infra/50-arc-runners-opshot/     # scale set bound to Arozhdan/opshot
secrets/arc-runners-opshot/      # SopsSecret carrying the GitHub PAT
```

## 1 — Generate a GitHub PAT

Classic PAT (not fine-grained) with scope `repo` (read+write). Workflows
will register, run, and de-register against this token.

GitHub UI: <https://github.com/settings/tokens/new?scopes=repo&description=ARC%20opshot>

Copy the `ghp_…` token. You won't see it again.

## 2 — Encrypt the PAT into SOPS

```bash
cd ~/environment

# 1. Edit the template, replace the placeholder with the real PAT
$EDITOR secrets/arc-runners-opshot/github-pat.example.yaml

# 2. Encrypt in place (requires SOPS_AGE_RECIPIENTS exported per docs/secrets.md)
sops --encrypt --in-place secrets/arc-runners-opshot/github-pat.example.yaml

# 3. Rename so the appset-secrets ApplicationSet picks it up
mv secrets/arc-runners-opshot/github-pat.example.yaml \
   secrets/arc-runners-opshot/github-pat.enc.yaml

# 4. Sanity-check (must show a sops: stanza, no plaintext stringData)
make check-sops
```

## 3 — Commit + push

```bash
git add infra/35-arc-controller infra/50-arc-runners-opshot secrets/arc-runners-opshot
git commit -m "infra: add actions-runner-controller v2 + opshot scale set"
git push
```

Argo CD picks it up via the directory ApplicationSets:

| Path | Sync wave | Argo App name |
|------|-----------|---------------|
| `infra/35-arc-controller` | 35 | `infra-35-arc-controller` |
| `infra/50-arc-runners-opshot` | 50 | `infra-50-arc-runners-opshot` |
| `secrets/arc-runners-opshot` | 30 | `secret-arc-runners-opshot` |

Order: SopsSecret materialises the K8s Secret at wave 30 → controller at 35 →
scale set at 50. The scale set looks up `arc-opshot-pat` in `arc-runners` ns
on startup; if it's missing, it CrashLoops until the secret appears (Argo
self-heals on the next sync).

## 4 — Verify the runner registered

```bash
# Pod is up
kubectl -n arc-runners get pods

# Listener pod logs should show "Listening for new jobs"
kubectl -n arc-runners logs -l app.kubernetes.io/name=opshot-runners-listener -f

# GitHub side
gh api repos/Arozhdan/opshot/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

You should see one runner with status `online` and label `opshot-runners`.

## 5 — Flip the workflow

In `~/applications/opshot/.github/workflows/ci.yml`, change the Linux jobs:

```yaml
# was: runs-on: ubuntu-latest
runs-on: opshot-runners
```

Keep `macos-latest` and `windows-latest` jobs on hosted runners — those don't
fit on the homelab cluster.

Push, watch Actions UI: the Linux jobs should target `opshot-runners`. The
listener pod logs show the job pickup; ephemeral runner pods spin up in
`arc-runners` namespace, run the job, terminate.

## Operations

**Stop accepting jobs (e.g. cluster maintenance):**
```bash
kubectl -n arc-runners scale autoscalingrunnerset/opshot-runners --replicas=0
```

**Bump the chart version** (do both controller + scale set together):
edit `version:` in both `infra/35-arc-controller/kustomization.yaml` and
`infra/50-arc-runners-opshot/kustomization.yaml`, push.

**Rotate the PAT:** edit `github-pat.enc.yaml` with `sops`, commit, push.
sops-secrets-operator detects the change and updates the underlying K8s Secret;
existing runner pods finish their current jobs then re-register with the new
token on next pickup.

**Watch for OCI Helm chart issues:** if Argo CD's bundled `helm` ever loses
OCI support, the kustomize+helm inflator will fail to pull the chart. Symptom:
`OutOfSync` on either Argo App with a `manifest generation` error mentioning
`oci://`. Fallback: replace `infra/35-arc-controller/kustomization.yaml`
contents with a direct Argo CD `Application` manifest using a Helm source.
