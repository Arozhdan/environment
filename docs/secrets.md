# Secrets with SOPS + age

This repo keeps encrypted secret apps under `secrets/<app>/` and rejects plaintext YAML under `secrets/`, except for the small `kustomization.yaml` files that wire encrypted manifests into Kustomize (see `scripts/check-sops.sh` and CI).

## One-time: create an age keypair

```bash
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt
```

Put the **public** key into `.sops.yaml` under `creation_rules[].age`.

Before you rely on any `SopsSecret`, create the operator's in-cluster age key Secret in `sops-system`:

```bash
kubectl -n sops-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

The operator chart mounts that Secret at `/etc/sops-age/age.agekey` via `infra/28-sops-secrets-operator/values.yaml`. See `infra/28-sops-secrets-operator/age-key-secret.example.yaml` for the expected shape.

Export for SOPS:

```bash
export SOPS_AGE_RECIPIENTS="$(age-keygen -y ~/.config/sops/age/keys.txt)"
```

## Encrypt files

```bash
sops --encrypt --in-place secrets/example.plain.yaml
mv secrets/example.plain.yaml secrets/example.enc.yaml  # if you rename
```

Create a secret app directory:

```bash
mkdir -p secrets/cloudflared
```

Create `secrets/cloudflared/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cloudflared-credentials.enc.yaml
```

Then create the encrypted manifest itself:

```bash
sops secrets/cloudflared/cloudflared-credentials.enc.yaml
```

## Decrypt locally (never commit plaintext)

```bash
sops -d secrets/cloudflared/cloudflared-credentials.enc.yaml
```

## In-cluster: sops-secrets-operator

After `infra/28-sops-secrets-operator` is healthy, use **`SopsSecret`** CRs (see [upstream docs](https://github.com/isindir/sops-secrets-operator)) so the controller materializes Kubernetes `Secret` objects from encrypted Git data.

Those manifests are reconciled by the `clusters/homelab-staging/appset-secrets.yaml` ApplicationSet, so anything under `secrets/<app>/` becomes part of the normal GitOps flow.

For Cloudflare Tunnel, create a `SopsSecret` that materializes a `Secret` named `cloudflared-credentials` in the `cloudflared` namespace, because `infra/30-cloudflared/deployment.yaml` mounts that name.

On the very first cluster bring-up, wait for `infra-28-sops-secrets-operator` to become healthy before you add `secrets/<app>/` directories to Git. That avoids a first-sync race where Argo sees `SopsSecret` manifests before the CRD/controller are ready.

## Cloudflare Tunnel JSON

Download the tunnel credentials JSON from Cloudflare (Zero Trust → Tunnels → your tunnel) and store it **only** inside SOPS-encrypted content, not as plaintext in Git.
