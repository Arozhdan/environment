# How This Homelab Works — A Complete Guide

This document explains everything we set up, why we set it up, how it all connects,
and what to do when you want to add something new. Written for someone who is not a
DevOps specialist but wants to actually understand what is going on — not just copy
commands.

---

## The Big Picture

You have a single computer running at home (the "homelab"). On it runs **k3s**, a
lightweight version of Kubernetes — the industry-standard system for running
containerized applications. Think of Kubernetes as the operating system for your
cluster: it decides where to run things, restarts them if they crash, and exposes
them to the network.

The problem with Kubernetes is that it is configured through hundreds of YAML files.
You could apply those files manually with `kubectl apply`, but then if the cluster
dies you have to remember everything you did. Instead, we use **GitOps**: the Git
repository IS the cluster. Every YAML file that should exist in the cluster lives in
Git. A tool called **Argo CD** runs inside the cluster, watches the Git repository,
and makes the cluster match whatever is in Git automatically.

The result: if the cluster dies, you reinstall k3s, run two `kubectl apply` commands,
and within minutes the cluster rebuilds itself from Git — every app, every setting,
every certificate, every secret.

---

## The Stack of Tools

### k3s — the cluster itself

k3s is Kubernetes but stripped down for single-node homelabs. It ships with a built-in
load balancer (ServiceLB) that assigns real IPs to services on your network.

We had to make two changes to the default k3s installation:

- **Disabled Traefik** — k3s ships with Traefik (an ingress controller) by default.
  We use ingress-nginx instead. Two ingress controllers can't both hold ports 80 and
  443 on the same host, so Traefik had to go. This is done via a flag in the k3s
  systemd service file.
- **Increased inotify limits** — k3s and all its pods open a lot of file watchers.
  Without higher limits, the system runs out and k3s fails to restart.

---

### Argo CD — the GitOps engine

Argo CD runs inside the cluster. Every few minutes (or immediately when you push to
Git) it compares what Git says should exist with what actually exists in the cluster.
If they differ, it applies the Git version. If something was changed manually in the
cluster, Argo reverts it.

**Why is this useful?**

- You can see the entire cluster state by reading files in Git
- Changes are reviewed before being applied (pull requests)
- History lives in git log
- Recovery from total cluster loss is mostly automatic

The Argo CD UI is at **https://argocd.tweak.codes**. Username is `admin`. The
password is retrieved with:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

### Helm — Kubernetes package manager

Helm is the package manager for Kubernetes. Community-maintained "charts" exist for
almost every tool (nginx, Prometheus, Loki, etc.). A chart is a collection of
templates that you configure with a `values.yaml` file. Instead of writing 3000 lines
of Prometheus YAML yourself, you write 30 lines of values and Helm generates the rest.

Helm knows nothing about your cluster or Git. It just takes a chart plus values and
produces Kubernetes YAML. That's its entire job.

---

### Kustomize — the adapter between Argo CD and external Helm charts

This one confuses people because it seems to overlap with Helm. Here is the honest
explanation.

**Argo CD can use Helm natively.** If you have a folder with a `Chart.yaml` in it,
Argo CD detects it and runs Helm automatically. No Kustomize needed for that.

**The problem comes from ApplicationSets.** We use ApplicationSets to auto-discover
apps — Argo CD scans `infra/*/` in your Git repo and creates one Application per
folder. But the charts for Loki, Grafana, ingress-nginx etc. are NOT in your Git repo.
They live on external Helm repositories (`https://grafana.github.io/helm-charts` etc.).

An ApplicationSet generator can only create Applications that point at your Git repo
folders. It cannot say "this folder should come from a different Helm repo URL". That
is the gap.

Kustomize fills that gap. Each `infra/*/kustomization.yaml` lives in your Git folder
(which the ApplicationSet can find) and says "go fetch this chart from this external
Helm repo and render it with these values". Argo CD runs Kustomize, Kustomize fetches
the external chart, and the combined output is applied to the cluster.

```
ApplicationSet scans infra/45-loki/ in your Git repo
  → finds kustomization.yaml (in Git)
  → kustomization.yaml says: fetch loki chart from grafana's helm repo
  → Kustomize downloads it, runs helm template, returns plain Kubernetes YAML
  → Argo CD applies that YAML to the cluster
```

**For your own apps with plain YAML files already in the repo** — Kustomize just
passes them through unchanged. The `kustomization.yaml` is just a list of which files
to include. It adds zero complexity.

```yaml
# apps/my-app/kustomization.yaml — for plain YAML apps
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

---

## The Repository Structure

```
environment.git/
├── bootstrap/          # One-time setup files — apply manually once when building cluster
│   └── argocd/
│       ├── install.yaml      # Installs Argo CD itself into the cluster
│       ├── root-app.yaml     # Tells Argo CD to watch clusters/homelab-staging/ in Git
│       ├── root-appset.yaml  # Old bootstrap file — superseded by root-app.yaml
│       └── values.yaml       # Argo CD configuration (ingress, insecure mode, etc.)
│
├── clusters/
│   └── homelab-staging/      # The authoritative ApplicationSet definitions
│       ├── kustomization.yaml
│       ├── appset-infra.yaml    # "create one Argo app per infra/* folder"
│       ├── appset-secrets.yaml  # "create one Argo app per secrets/* folder"
│       └── appset-apps.yaml     # "create one Argo app per apps/* folder"
│
├── infra/              # Platform services (numbered for install order)
│   ├── 10-cert-manager/
│   ├── 20-ingress-nginx/
│   ├── 28-sops-secrets-operator/
│   ├── 30-cloudflared/
│   ├── 40-kube-prometheus-stack/
│   ├── 45-loki/
│   └── 46-alloy/
│
├── apps/               # Your actual applications
│   └── hello/
│
├── secrets/            # SOPS-encrypted secrets only (never plaintext here)
│   └── cloudflared/
│
├── docs/               # Documentation
├── .sops.yaml          # Tells SOPS which public key to use when encrypting
└── renovate.json       # Automated dependency update bot config
```

**Important distinction between `bootstrap/` and `clusters/`:**

- `bootstrap/` — files you apply manually **once** when setting up a new cluster.
  After that they are reference only. You only touch them again to change how Argo CD
  itself is configured (like adding an ingress for the UI).
- `clusters/homelab-staging/` — the ongoing GitOps source of truth for your cluster
  configuration. Changes here are applied automatically by the `homelab-staging-root`
  Argo CD Application.

---

## How Argo CD Discovers Everything (ApplicationSets)

You have three ApplicationSets, each scanning a different folder pattern:

**`appset-infra.yaml`** — watches `infra/*`
```
infra/10-cert-manager/  → Argo CD app "infra-10-cert-manager"
infra/20-ingress-nginx/ → Argo CD app "infra-20-ingress-nginx"
... and so on for each infra/* folder
```

**`appset-apps.yaml`** — watches `apps/*`
```
apps/hello/ → Argo CD app "app-hello"
```

**`appset-secrets.yaml`** — watches `secrets/*`
```
secrets/cloudflared/ → Argo CD app "secret-cloudflared"
```

**To add a new application, you just create a new folder.** Argo CD discovers it
automatically within a few minutes. No Argo CD configuration needed.

**The numbers in `infra/`** (10, 20, 28, 30...) control install order. cert-manager
must be installed before things that need TLS certificates. The numbers become
sync-wave annotations telling Argo CD "don't start wave 20 until wave 10 is healthy".

---

## The Infrastructure Apps Explained

### `infra/10-cert-manager` — Automatic TLS Certificates

**What it does:** Automatically obtains and renews TLS certificates from Let's Encrypt.
You annotate an Ingress resource with one line and cert-manager handles everything:
requesting the certificate, proving domain ownership, receiving the cert, and renewing
it before it expires.

**Do you need this if you have Cloudflare Tunnel?** Technically no. Cloudflare
terminates TLS at its edge using its own certificate — your users get a valid padlock
without cert-manager. The internal traffic from cloudflared to ingress-nginx is plain
HTTP inside your cluster.

cert-manager adds a second layer: it also encrypts the ingress-nginx → app leg using
a Let's Encrypt certificate. This is "defence in depth" — useful if you ever access
the cluster directly without going through Cloudflare. For a homelab it's optional,
but it costs nothing to have it.

**Technical:** cert-manager manages `Certificate`, `CertificateRequest`, and
`ClusterIssuer` custom resources. We use ACME HTTP-01 challenges via Let's Encrypt
production (`letsencrypt-prod`). Your email (`halala30@gmail.com`) is registered with
Let's Encrypt so they can notify you about problems.

---

### `infra/20-ingress-nginx` — HTTP Traffic Routing Inside the Cluster

**What it does:** Acts as a reverse proxy — a single entry point inside the cluster
that routes HTTP traffic to the right service based on the hostname.

```
argocd.tweak.codes  → argocd-server service in argocd namespace
grafana.tweak.codes → grafana service in monitoring namespace
hello.tweak.codes   → hello service in hello namespace
```

Think of it as a hotel reception desk: one door in, the receptionist routes you to
the right room based on who you are.

**Technical:** ingress-nginx watches `Ingress` resources across all namespaces and
configures an nginx process accordingly. It is exposed as a `LoadBalancer` service,
which means k3s's ServiceLB binds your node's IP (`192.168.0.144`) to ports 80 and
443 on the host.

---

### `infra/28-sops-secrets-operator` — Encrypted Secrets in Git

**What it does:** Watches for `SopsSecret` resources in the cluster, decrypts them
using your age private key, and creates regular Kubernetes `Secret` objects that apps
can use.

This is what makes it safe to store encrypted credentials in Git. See the SOPS section
below for the full explanation.

---

### `infra/30-cloudflared` — The Cloudflare Tunnel

**What it does:** Exposes your cluster to the internet without opening any ports on
your router and without needing a static IP.

Instead of the internet connecting TO your server, your server connects OUT to
Cloudflare. The `cloudflared` pod maintains a persistent outbound connection to
Cloudflare's global network. When someone visits `hello.tweak.codes`:

```
Browser → Cloudflare edge → through the outbound tunnel → cloudflared pod
       → ingress-nginx → hello app
```

Your home IP is never exposed. No port forwarding. Works even if your ISP blocks
inbound connections.

**Important detail about the config:** The cloudflared config (`config.yaml`) uses a
wildcard rule:

```yaml
ingress:
  - hostname: "*.tweak.codes"
    service: http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
  - service: http_status:404
```

This means **any** subdomain of `tweak.codes` is automatically forwarded to
ingress-nginx. You do NOT need to add new hostnames to this file when adding a new
app. Just create an `Ingress` resource in your app and it works automatically.

**About the host vs cluster cloudflared:** When we started, there was also a cloudflared
process running as a systemd service on the host machine (the homelab OS itself, not
inside Kubernetes). It had been installed manually before this GitOps setup. We
migrated everything to the cluster pod and disabled the host service (`systemctl
disable --now cloudflared`). The cluster pod is now the only cloudflared.

**Restarting after config changes:** cloudflared reads its config once at startup and
never re-reads it. When Argo CD updates the ConfigMap (which backs `config.yaml`), the
running pod doesn't notice. You must restart the pod to pick up changes:

```bash
kubectl -n cloudflared rollout restart deployment/cloudflared
```

This is a known Kubernetes behaviour — most applications don't watch config files for
changes while running.

---

### `infra/40-kube-prometheus-stack` — Metrics and Grafana

**What it installs:**

- **Prometheus** — collects and stores metrics (numbers over time: CPU, memory,
  request counts, etc.)
- **Grafana** — dashboard UI at `https://grafana.tweak.codes`
- **Alertmanager** — sends alerts when something goes wrong
- **kube-state-metrics** — Kubernetes-level metrics (pod counts, health status, etc.)
- **node-exporter** — host-level metrics (disk space, network, CPU per core)

**Technical:** Uses the Prometheus Operator pattern. Instead of raw Prometheus config,
you create `ServiceMonitor` and `PrometheusRule` custom resources. The operator
translates these into Prometheus configuration. This is why `includeCRDs: true` is
essential — the CRDs must exist before any of those resources can be created.

---

### `infra/45-loki` — Log Storage

**What it does:** Stores logs from all your pods. You query logs in Grafana alongside
metrics — when an app crashes, you look at its logs to see the error.

**Technical:** Runs in `SingleBinary` mode — one pod, filesystem storage on a 10Gi
PVC. No object storage (S3) needed. `replication_factor: 1` means no redundancy,
which is fine for a homelab.

---

### `infra/46-alloy` — Log and Metric Collector

**What it does:** Ships logs FROM pods TO Loki. Runs as a DaemonSet (one instance on
every node), watches every pod's stdout/stderr, and forwards to Loki.

**Technical:** Uses the River configuration language. Discovers pods via the Kubernetes
API, tails their logs, pushes to `http://loki.observability.svc.cluster.local:3100`
(Kubernetes internal DNS — traffic never leaves the cluster).

---

## The Application: `apps/hello`

A demo nginx container that proves the entire stack works end-to-end. Accessible at
`https://hello.tweak.codes`.

Files:
- `deployment.yaml` — one nginx pod
- `service.yaml` — exposes the pod inside the cluster on port 80
- `ingress.yaml` — tells ingress-nginx to route `hello.tweak.codes` to the service
- `networkpolicy.yaml` — only allows traffic from ingress-nginx (security)
- `namespace.yaml` — creates the `hello` namespace

---

## SOPS and Age Keys — Secrets Explained Fully

### The Problem

You need the Cloudflare tunnel credentials in the cluster so `cloudflared` can
authenticate. But you also want everything in Git so the cluster can be rebuilt. You
cannot put raw secrets in Git.

### The Solution: Asymmetric Encryption

You generate a **keypair**:

- **Public key** (`age1p6z3qj...`) — used to encrypt. Safe to share, in `.sops.yaml`.
- **Private key** (`AGE-SECRET-KEY-...`) — used to decrypt. Never commit this anywhere.

Your private key lives at `~/.config/sops/age/keys.txt` on the homelab host.

### SOPS — Encrypts YAML Files

SOPS (Secrets OPerationS) encrypts YAML files using your age key. It encrypts the
values but leaves the keys readable:

```yaml
# After encryption — safe to commit
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
    name: cloudflared-credentials    # readable
spec:
    secretTemplates:
        - stringData:
              credentials.json: ENC[AES256_GCM,data:xxxencryptedxxx,...]
sops:
    age:
        - recipient: age1p6z3qj...   # your public key
```

### Where is `SOPS_AGE_KEY_FILE`?

This is an environment variable that tells SOPS where the private key file is. It does
NOT live on your host machine's shell environment. It lives **inside the
sops-secrets-operator pod** only.

The chain:

```
Your private key file: ~/.config/sops/age/keys.txt   (homelab host filesystem)
         │
         │  you ran: kubectl create secret generic sops-age --from-file=...
         ▼
Kubernetes Secret "sops-age" in sops-system namespace  (stored in cluster's etcd)
         │
         │  the operator mounts this Secret as a file inside the pod
         ▼
/etc/sops-age/age.agekey   (inside the sops-secrets-operator container only)
         │
         │  env var SOPS_AGE_KEY_FILE=/etc/sops-age/age.agekey set in the pod
         ▼
operator uses it to decrypt SopsSecret resources and create plain k8s Secrets
```

To verify it's working inside the pod:

```bash
kubectl -n sops-system exec -it \
  $(kubectl -n sops-system get pod -l app.kubernetes.io/name=sops-secrets-operator -o name) \
  -- env | grep SOPS
```

### The Full Secrets Flow

```
1. Create a plain SopsSecret YAML file on the homelab host (never commit this)
2. Encrypt it: sops --encrypt file.yaml > secrets/my-app/file.enc.yaml
3. Commit and push the encrypted file
4. Argo CD detects the new secrets/my-app/ folder
5. Argo CD applies the SopsSecret resource to the cluster
6. sops-secrets-operator sees the SopsSecret
7. It uses the private key (from the sops-age k8s Secret) to decrypt
8. It creates a regular k8s Secret with the decrypted values
9. Your app mounts that Secret and uses the credentials
```

The private key is the only thing not in Git.

---

## How Traffic Actually Flows

When someone visits `https://hello.tweak.codes`:

```
1. Browser contacts Cloudflare DNS
   → gets a Cloudflare IP (your home IP is never revealed)

2. Browser connects to Cloudflare edge over HTTPS
   → Cloudflare terminates TLS using their own certificate
   → your users see a valid padlock here

3. Cloudflare sends the request through the persistent tunnel

4. cloudflared pod in your cluster receives it (plain HTTP now)

5. cloudflared matches "*.tweak.codes" → forwards to ingress-nginx
   URL: http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80

6. ingress-nginx checks its Ingress rules
   → finds: "hello.tweak.codes → service hello in namespace hello"

7. ingress-nginx proxies to the hello Service → hello Pod

8. Response travels back the same path
```

---

## How to Add a New Application

### Simple app with plain YAML

1. Create `apps/my-app/` with these files:

**`kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: my-app
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

**`namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
```

**`deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: my-app
  template:
    metadata:
      labels:
        app.kubernetes.io/name: my-app
    spec:
      containers:
        - name: my-app
          image: my-image:tag
          ports:
            - containerPort: 3000
```

**`service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: my-app
spec:
  selector:
    app.kubernetes.io/name: my-app
  ports:
    - port: 80
      targetPort: 3000
```

**`ingress.yaml`**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - my-app.tweak.codes
      secretName: my-app-tls
  rules:
    - host: my-app.tweak.codes
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

2. Commit and push:

```bash
git add apps/my-app/
git commit -m "feat: add my-app"
git push origin main
```

That's it. Because cloudflared uses a wildcard (`*.tweak.codes → ingress-nginx`), the
subdomain is automatically routed. No changes to cloudflared config. No DNS changes.
Just the Ingress is enough.

Argo CD picks up the new folder within a few minutes and deploys everything.

---

### App using an external Helm chart

Use `infra/` instead of `apps/`. Create `infra/NN-my-app/`:

**`kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: my-chart
    repo: https://charts.example.com
    version: 1.2.3
    releaseName: my-app
    namespace: my-app
    valuesFile: values.yaml
    includeCRDs: true   # always add this — costs nothing if the chart has no CRDs
```

**`values.yaml`** — your chart configuration.

---

### App that needs a secret

1. On the homelab host, create a plain YAML file (never commit this version):

```yaml
# /tmp/my-app-secret.yaml  — plain, do not commit
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: my-app-secret
  namespace: my-app
spec:
  secretTemplates:
    - name: my-app-secret
      stringData:
        API_KEY: "my-actual-api-key"
```

2. Encrypt it:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
sops --encrypt \
  --age age1p6z3qj3swz7g6c5qtwtyuzvm7nvxxjlvmuk8mnk00zc83yazpp7q4r0fpj \
  /tmp/my-app-secret.yaml > secrets/my-app/my-app-secret.enc.yaml
```

3. Create `secrets/my-app/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - my-app-secret.enc.yaml
```

4. Reference the secret in your Deployment:

```yaml
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: my-app-secret
        key: API_KEY
```

5. Commit and push. The sops-secrets-operator decrypts it and creates the k8s Secret.

---

## Day-to-Day Operations

### See the state of all apps

```bash
kubectl -n argocd get applications --sort-by=.metadata.name \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

### Force a sync immediately

```bash
kubectl -n argocd patch application app-hello \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"prune":true}}}'
```

### Force Argo CD to re-read from Git

```bash
kubectl -n argocd annotate application app-hello \
  argocd.argoproj.io/refresh=hard --overwrite
```

### Restart an app (picks up ConfigMap changes too)

```bash
kubectl -n hello rollout restart deployment/hello
```

### See pod logs

```bash
kubectl -n hello get pods                    # find the pod name
kubectl -n hello logs hello-xxxxx-yyyyy
```

### See why a pod is not starting

```bash
kubectl -n hello describe pod hello-xxxxx-yyyyy
```

### Check certificates

```bash
kubectl get certificates -A
# READY=True means the cert is valid and trusted
```

---

## The Bootstrap Sequence (What to Do on a Fresh Cluster)

```bash
# 1. Install k3s
curl -sfL https://get.k3s.io | sh -

# 2. Disable Traefik (it conflicts with ingress-nginx on ports 80/443)
sudo nano /etc/systemd/system/k3s.service
# Add under ExecStart:  '--disable' \ 'traefik' \
sudo systemctl daemon-reload && sudo systemctl restart k3s

# 3. Increase inotify limits
sudo sysctl fs.inotify.max_user_instances=8192
sudo sysctl fs.inotify.max_user_watches=524288
echo "fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288" | sudo tee /etc/sysctl.d/99-inotify.conf

# 4. Install Argo CD (one time)
kubectl create namespace argocd
kubectl apply -f bootstrap/argocd/install.yaml

# 5. Tell Argo CD to manage itself and the cluster from Git
kubectl apply -f bootstrap/argocd/root-app.yaml

# 6. Create the age key Secret (the one thing not in Git)
kubectl -n sops-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt

# 7. Create the Cloudflare tunnel credentials Secret
kubectl -n cloudflared create secret generic cloudflared-credentials \
  --from-file=credentials.json=$HOME/.cloudflared/63b08bb5-8d1b-4232-aea3-1bf198fe581b.json

# 8. Wait — Argo CD discovers everything from Git and deploys automatically
kubectl -n argocd get applications --watch
```

Steps 6 and 7 are the only things not in Git. Everything else rebuilds automatically.

---

## Common Questions

**Why are the infra folders numbered?**
The numbers (10, 20, 28...) control install order. cert-manager must be running before
ingress-nginx validates Ingress resources, which must be running before cloudflared
routes traffic. The numbers become Argo CD sync-wave annotations.

**What is `includeCRDs: true`?**
Some Helm charts (like kube-prometheus-stack and sops-secrets-operator) install new
Kubernetes resource types (Custom Resource Definitions). These must exist before any
resources of those types can be created. Without `includeCRDs: true`, Argo CD tries
to create `PrometheusRule` resources before Kubernetes even knows what a
`PrometheusRule` is, and fails with "CRD not found".

**What is `ServerSideApply=true`?**
A safer apply mode where the Kubernetes server computes the diff instead of the client.
Reduces false conflicts when Kubernetes has added its own default values to resources.

**What is `CreateNamespace=true`?**
Argo CD will create the namespace before deploying resources into it. Without this, if
the namespace doesn't exist yet, the sync fails.

**Why does infra-45-loki sometimes show OutOfSync?**
Kubernetes adds a `volumeMode: Filesystem` field to the Loki StatefulSet's storage
spec after creation. This field is not in the Helm template. We added an
`ignoreDifferences` rule to Argo CD to ignore this specific field. It is cosmetic and
does not affect how Loki works.

**I changed cloudflared's `config.yaml` but it didn't take effect. Why?**
The cloudflared process reads its config once at startup. Argo CD updating the
ConfigMap changes the file on disk but the running process has the old config in
memory. You must restart the pod: `kubectl -n cloudflared rollout restart deployment/cloudflared`.

**Do I need to update `infra/30-cloudflared/config.yaml` when adding a new subdomain?**
No. The cloudflared config uses a wildcard `*.tweak.codes → ingress-nginx`. Any
subdomain automatically reaches nginx. Just add an `Ingress` resource in your app.

**Why `server.insecure: true` for Argo CD?**
With Cloudflare Tunnel, TLS is terminated at Cloudflare's edge. Traffic from
cloudflared to ingress-nginx to Argo CD is plain HTTP inside the cluster. By default,
Argo CD redirects any HTTP request to HTTPS, creating an infinite redirect loop.
`server.insecure: true` tells Argo CD "trust that whoever is in front of me handled
TLS" and serve the page directly.

**What happens if I delete an Argo CD Application?**
The `infra/` and `apps/` ApplicationSets have `finalizers: resources-finalizer`, so
deleting an Application cascades and also deletes all the Kubernetes resources it
manages. The `homelab-staging-root` Application does NOT have a finalizer — deleting
it only removes the Application object, not the ApplicationSets it manages.

**Why is the Grafana admin password in plain YAML?**
It is a known TODO. The correct fix is to encrypt it with SOPS as a SopsSecret and
reference it. For now it works but anyone with repo access can see it.
