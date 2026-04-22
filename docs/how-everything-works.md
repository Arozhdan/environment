# How This Homelab Works — A Complete Guide

This document explains everything we set up, why we set it up, how it all connects,
and what to do when you want to add something new. Written for someone who is not a
DevOps specialist.

---

## The Big Picture

You have a single computer running at home (the "homelab"). On it runs **k3s**, a
lightweight version of Kubernetes — the industry-standard system for running
containerized applications. Think of Kubernetes as the operating system for your
cluster: it decides where to run things, restarts them if they crash, and exposes
them to the network.

The problem with Kubernetes is that it is configured through hundreds of YAML files.
You could apply those files manually with `kubectl apply`, but then if the cluster
dies you have to remember everything. Instead, we use **GitOps**: the Git repository
IS the cluster. Every YAML file that should exist in the cluster lives in Git. A tool
called **Argo CD** runs inside the cluster, watches the Git repository, and makes the
cluster match whatever is in Git automatically.

The result: if the cluster dies, you reinstall k3s, run two `kubectl apply` commands,
and within minutes the cluster rebuilds itself from Git — every app, every setting,
every certificate, every secret.

---

## The Stack of Tools

### k3s — the cluster itself

k3s is Kubernetes but stripped down for single-node homelabs. It ships with:

- A built-in load balancer (ServiceLB, which assigns IPs to services)
- A built-in storage driver
- No Traefik by default (we removed it because we use ingress-nginx instead)

**Why k3s and not full Kubernetes?** Because running a full 3-node Kubernetes cluster
at home is overkill and expensive. k3s does 95% of the same things.

### Argo CD — the GitOps engine

Argo CD runs inside the cluster. Every 3 minutes (or immediately when you push to Git)
it compares what Git says should exist with what actually exists in the cluster. If
they differ, it applies the Git version. If something was changed manually in the
cluster, Argo reverts it.

**Why is this useful?** Because "the cluster should look like Git" means:

- You can see the entire cluster state by reading files
- Changes are reviewed in pull requests
- History is in git log
- Recovery is automatic

### Kustomize and Helm — the YAML assemblers

Kubernetes resources are YAML files. Writing raw YAML for every app gets repetitive.

**Helm** is a package manager for Kubernetes. Community-maintained "charts" exist for
almost every tool (nginx, Prometheus, Loki, etc.). A chart is a template that you
configure with a `values.yaml` file. Instead of writing 3000 lines of Prometheus YAML
yourself, you write 30 lines of values and Helm generates the rest.

**Kustomize** is a tool that assembles YAML from multiple sources. In this repo, each
`infra/*/kustomization.yaml` file tells Kustomize: "take this Helm chart, use these
values, and also include these extra YAML files". Argo CD runs Kustomize (with Helm)
to generate the final YAML that gets applied to the cluster.

Technical flow:

```
Git: infra/20-ingress-nginx/kustomization.yaml
         + values.yaml
         + namespace.yaml
         ↓
Argo CD runs: kustomize build --enable-helm
         ↓
Generated: ~500 lines of nginx Deployment, Service, RBAC, etc.
         ↓
Applied to cluster via kubectl
```

---

## The Repository Structure

```
environment.git/
├── bootstrap/          # One-time setup files (applied manually once)
│   └── argocd/
│       ├── install.yaml      # Tells Argo CD to manage itself from Git
│       ├── root-app.yaml     # Tells Argo CD to watch clusters/homelab-staging/
│       ├── root-appset.yaml  # Convenience copy of the ApplicationSets (bootstrap only)
│       └── values.yaml       # Argo CD Helm chart configuration
│
├── clusters/
│   └── homelab-staging/      # The authoritative config for your cluster
│       ├── kustomization.yaml
│       ├── appset-infra.yaml    # "watch infra/* in Git"
│       ├── appset-secrets.yaml  # "watch secrets/* in Git"
│       └── appset-apps.yaml     # "watch apps/* in Git"
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
├── secrets/            # Encrypted secrets only (never plaintext)
│   └── cloudflared/
│
├── docs/               # Documentation
├── .sops.yaml          # Encryption configuration
└── renovate.json       # Automated dependency update config
```

---

## How Argo CD Discovers Everything (ApplicationSets)

The key to how everything is wired together is **ApplicationSets**. An ApplicationSet
is an Argo CD resource that says: "for every directory matching this pattern in Git,
create one Argo CD Application".

You have three ApplicationSets:

`**appset-infra.yaml`** — watches `infra/`*

```
infra/10-cert-manager/   → creates Argo CD app "infra-10-cert-manager"
infra/20-ingress-nginx/  → creates Argo CD app "infra-20-ingress-nginx"
infra/28-sops-...        → creates Argo CD app "infra-28-sops-secrets-operator"
... and so on
```

`**appset-apps.yaml**` — watches `apps/*`

```
apps/hello/  → creates Argo CD app "app-hello"
```

`**appset-secrets.yaml**` — watches `secrets/*`

```
secrets/cloudflared/  → creates Argo CD app "secret-cloudflared"
```

This means: **to add a new application, you just create a new folder**. Argo CD
discovers it automatically within a few minutes. No manual Argo CD configuration
needed.

The **numbers in `infra/`** (10, 20, 28, 30...) are used to control install order.
cert-manager must be installed before things that need TLS certificates. The numbers
become sync-wave annotations, which tell Argo CD "don't start wave 20 until wave 10
is healthy".

---

## The Infrastructure Apps Explained

### `infra/10-cert-manager` — Automatic TLS Certificates

**Human explanation:** When you visit `https://hello.tweak.codes`, your browser
requires a TLS certificate to establish a secure connection. Getting a free certificate
from Let's Encrypt used to be a manual process. cert-manager automates this entirely.
You just annotate an Ingress (the routing rule) with one line and cert-manager:

1. Creates a certificate request with Let's Encrypt
2. Proves you own the domain by serving a special file at `/.well-known/acme-challenge/`
3. Receives and stores the certificate
4. Renews it automatically before it expires

**Technical:** cert-manager is a Kubernetes controller that manages `Certificate`,
`CertificateRequest`, and `ClusterIssuer` custom resources. The `ClusterIssuer`
defines how to obtain certs — we use ACME HTTP-01 challenges via Let's Encrypt.
There are two issuers:

- `letsencrypt-staging` — for testing (gives untrusted certs, higher rate limits)
- `letsencrypt-prod` — real trusted certificates

The `clusterissuers.yaml` file sets your email so Let's Encrypt can notify you about
certificate problems.

---

### `infra/20-ingress-nginx` — HTTP Traffic Routing

**Human explanation:** Your cluster runs many services (hello app, Grafana, etc.).
They all need to be reachable via HTTP/HTTPS. ingress-nginx acts as a reverse proxy —
a single entry point that routes traffic to the right service based on the hostname.

```
https://hello.tweak.codes   → hello app
https://grafana.tweak.codes → Grafana
```

Think of it like a hotel reception desk: one door, the receptionist routes you to the
right room based on who you are.

**Technical:** ingress-nginx is a Kubernetes `IngressController`. It watches `Ingress`
resources across the cluster and configures an nginx process to proxy traffic to the
correct backend `Service`. It's exposed as a `LoadBalancer` service, which means k3s's
ServiceLB assigns your node's IP (192.168.0.144) and opens ports 80 and 443 on the
host.

We had to disable k3s's built-in Traefik (another ingress controller) because two
ingress controllers can't both hold ports 80 and 443 on the same host.

---

### `infra/28-sops-secrets-operator` — Encrypted Secrets in Git

**Human explanation:** You need passwords and API credentials in the cluster (tunnel
credentials, Grafana admin password, etc.). You can't commit them to Git in plaintext
— anyone with repo access would see them. The sops-secrets-operator solves this: you
encrypt credentials before committing them, and this operator decrypts them inside the
cluster.

**Technical:** The operator watches for `SopsSecret` custom resources in the cluster.
When it finds one, it uses the age private key (stored as a Kubernetes Secret named
`sops-age` in the `sops-system` namespace) to decrypt the encrypted values and create
regular Kubernetes `Secret` objects that other apps can use.

The age key is the only thing that can never be in Git (it's the decryption key). It
lives only on your homelab host at `~/.config/sops/age/keys.txt` and as a Kubernetes
Secret in the cluster.

See the SOPS section below for a full explanation.

---

### `infra/30-cloudflared` — The Cloudflare Tunnel

**Human explanation:** Your homelab is on a home network with a dynamic IP address
that changes. You can't just open port 80/443 on your router and tell the world "my
server is at 86.x.x.x" because that IP changes and it's a security risk. Cloudflare
Tunnel solves this differently.

Instead of the internet connecting TO your server, your server connects OUT to
Cloudflare. A process called `cloudflared` runs inside your cluster and maintains a
persistent outbound connection to Cloudflare's global network. When someone visits
`hello.tweak.codes`, the traffic goes:

```
User's browser
    ↓
Cloudflare edge servers (distributed globally)
    ↓  [through the outbound tunnel]
cloudflared pod in your cluster
    ↓  [internal cluster networking]
ingress-nginx
    ↓
hello app
```

Your home IP is never exposed. No port forwarding needed. Works even if your ISP
blocks inbound connections.

**Technical:** The `cloudflared` Deployment runs the Cloudflare tunnel client. It
reads two things:

1. `config.yaml` (as a ConfigMap) — which hostnames to route where
2. `cloudflared-credentials` (as a Secret) — authenticates to Cloudflare

The config routes both `hello.tweak.codes` and `grafana.tweak.codes` to
`ingress-nginx`, which then routes them further based on the Ingress rules.

The tunnel was created with `cloudflared tunnel create homelab` and linked to your
Cloudflare account. DNS entries (`CNAME → tunnel-id.cfargotunnel.com`) were created
with `cloudflared tunnel route dns`.

---

### `infra/40-kube-prometheus-stack` — Metrics and Grafana

**Human explanation:** You need to know if your cluster is healthy, how much memory
it uses, if any pod is crashing, etc. kube-prometheus-stack installs everything you
need for monitoring in one go.

**What it installs:**

- **Prometheus** — collects and stores metrics (numbers over time: CPU usage, memory,
request count, etc.)
- **Grafana** — the dashboard UI where you visualize metrics as graphs
- **Alertmanager** — sends alerts when something goes wrong
- **kube-state-metrics** — exports Kubernetes-level metrics (how many pods are running,
are they healthy, etc.)
- **node-exporter** — exports host-level metrics (disk space, network, CPU per core)

Grafana is exposed at `https://grafana.tweak.codes` via ingress-nginx + Cloudflare
Tunnel. It is pre-configured with Prometheus as a data source and includes dashboards
for node metrics, pod metrics, and everything Kubernetes-related.

**Technical:** The kube-prometheus-stack Helm chart uses the Prometheus Operator
pattern. Instead of configuring Prometheus with raw YAML, you create `ServiceMonitor`
and `PrometheusRule` custom resources that the operator translates into Prometheus
configuration. This is why `includeCRDs: true` is essential — the custom resource
definitions must exist before any of those resources can be applied.

---

### `infra/45-loki` — Log Storage

**Human explanation:** Metrics tell you numbers. Logs tell you what actually happened.
When an app crashes, you look at its logs to see the error. Loki is a log storage
system designed to work alongside Prometheus. You can query logs in Grafana using the
same interface as metrics.

**Technical:** Loki runs in `SingleBinary` mode — a single pod that handles writes
and queries. It stores logs on disk (a 10Gi PersistentVolumeClaim). It uses filesystem
storage instead of object storage (S3) because this is a homelab and we don't have S3.

The `replication_factor: 1` setting means there's no data redundancy — one pod, one
copy. Acceptable for a homelab; you'd use 3 for production.

---

### `infra/46-alloy` — Log and Metric Collector

**Human explanation:** Loki stores logs but something has to ship the logs from your
pods to Loki. Alloy (formerly Grafana Agent) is that collector. It runs on every node
(as a DaemonSet), watches every pod's stdout/stderr, and forwards the log lines to
Loki.

**Technical:** Alloy's configuration (in `values.yaml`) uses the River configuration
language to:

1. Discover all pods via the Kubernetes API (`discovery.kubernetes "pods"`)
2. Tail logs from those pods (`loki.source.kubernetes "k8s"`)
3. Push to Loki's API (`loki.write "default"` pointing to
  `http://loki.observability.svc.cluster.local:3100`)

`svc.cluster.local` is Kubernetes internal DNS — Alloy talks to Loki without leaving
the cluster.

---

## The Application: `apps/hello`

This is your demo application. It's a plain nginx web server that serves the default
nginx welcome page. Its purpose is to prove the entire stack works end-to-end.

The `apps/hello/` directory contains:

- `deployment.yaml` — runs one nginx pod
- `service.yaml` — exposes the pod inside the cluster on port 80
- `ingress.yaml` — tells ingress-nginx to route `hello.tweak.codes` to the service
- `networkpolicy.yaml` — only allows traffic from ingress-nginx (security)
- `namespace.yaml` — creates the `hello` namespace

The Ingress annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` is what
triggers cert-manager to obtain a TLS certificate automatically.

---

## SOPS and Age Keys — Secrets Explained Fully

This is the part that confuses most people. Let's go from first principles.

### The Problem

You need the Cloudflare tunnel credentials (`credentials.json`) in the cluster so
`cloudflared` can authenticate. But you also want to keep them in Git so everything
is reproducible. You can't put raw secrets in Git — anyone with repo access sees them.

### The Solution: Encryption

You encrypt the secret before committing it. Only someone with the decryption key can
read it. The decryption key never goes in Git.

### age — the Encryption Tool

`age` is a modern encryption tool. You generate a **keypair**:

- A **public key** (`age1p6z3qj...`) — used to encrypt. Safe to share, put in Git.
- A **private key** (`AGE-SECRET-KEY-...`) — used to decrypt. Never share, never
commit.

Your private key lives at `~/.config/sops/age/keys.txt` on the homelab host. Your
public key is in `.sops.yaml` in this repo.

### SOPS — Encrypts YAML Files

SOPS (Secrets OPerationS) is a tool that encrypts YAML files using age keys. When you
run `sops --encrypt file.yaml`, it:

1. Reads the YAML
2. Encrypts every value (leaves keys readable)
3. Writes an encrypted file

The result looks like:

```yaml
# Encrypted file — safe to commit
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
    name: cloudflared-credentials  # readable
spec:
    secretTemplates:
        - name: cloudflared-credentials
          stringData:
              credentials.json: ENC[AES256_GCM,data:xxxxxencryptedxxxxx,...]
sops:
    age:
        - recipient: age1p6z3qj...   # your public key
          enc: |
              -----BEGIN AGE ENCRYPTED FILE-----
              ...
```

The values are encrypted but the structure is readable. You can see what kind of
secret it is, what namespace it goes in, just not the actual content.

### `SOPS_AGE_KEY_FILE` — the Environment Variable

When you run `sops --decrypt file.yaml`, SOPS needs to find your private key. The
`SOPS_AGE_KEY_FILE` environment variable tells it where the private key file is:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

The sops-secrets-operator uses the same mechanism inside the cluster. Look at
`infra/28-sops-secrets-operator/values.yaml`:

```yaml
extraEnv:
  - name: SOPS_AGE_KEY_FILE
    value: /etc/sops-age/age.agekey   # path inside the pod
secretsAsFiles:
  - name: sops-age
    mountPath: /etc/sops-age
    secretName: sops-age              # k8s Secret that holds the private key
```

The operator pod has the private key mounted as a file, so it can decrypt any
`SopsSecret` resource it finds in the cluster.

### `.sops.yaml` — Encryption Config

The `.sops.yaml` file in the repo root tells SOPS: "when encrypting any file matching
`*.enc.yaml`, use this public key as the recipient":

```yaml
creation_rules:
  - path_regex: \.enc\.ya?ml$
    age: >-
      age1p6z3qj3swz7g6c5qtwtyuzvm7nvxxjlvmuk8mnk00zc83yazpp7q4r0fpj
```

### The Full Secrets Flow

```
1. You create a plain YAML SopsSecret file on the homelab host
2. You run: sops --encrypt file.yaml > file.enc.yaml
   (SOPS uses the public key from .sops.yaml to encrypt)
3. You commit and push file.enc.yaml to Git
4. Argo CD detects the new file in secrets/cloudflared/
5. Argo CD applies the SopsSecret resource to the cluster
6. sops-secrets-operator sees the SopsSecret
7. It uses the private key (from the sops-age k8s Secret) to decrypt
8. It creates a regular k8s Secret with the decrypted values
9. cloudflared mounts that Secret and authenticates with Cloudflare
```

The private key (`AGE-SECRET-KEY-...`) is the only thing that is NOT in Git.

---

## How Traffic Actually Flows

When someone visits `https://hello.tweak.codes`:

```
1. Browser contacts Cloudflare DNS → gets Cloudflare IP (not your home IP)
2. Browser connects to Cloudflare edge server over HTTPS
   (Cloudflare terminates TLS using their certificate)
3. Cloudflare looks up the tunnel for tweak.codes
4. Cloudflare sends the request through the tunnel to your cluster
5. cloudflared pod receives the request
6. cloudflared looks at config.yaml: "hello.tweak.codes → ingress-nginx"
7. cloudflared forwards to: http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
8. ingress-nginx receives the request, checks its Ingress rules
9. ingress-nginx finds: "hello.tweak.codes → service hello in namespace hello, port 80"
10. ingress-nginx proxies to the hello Service
11. The Service routes to the hello Pod (nginx container)
12. Response travels back the same path
```

Note: there are TWO TLS layers:

- Cloudflare to your browser: Cloudflare's own certificate
- ingress-nginx also has a Let's Encrypt certificate (from cert-manager) but it's
not used for external traffic when behind Cloudflare Tunnel — Cloudflare handles
the public-facing TLS

---

## How to Add a New Application

### Simple App (just a container)

1. Create a directory `apps/my-app/`
2. Create these files:

`**apps/my-app/kustomization.yaml**`

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

`**apps/my-app/namespace.yaml**`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
```

`**apps/my-app/deployment.yaml**`

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

`**apps/my-app/service.yaml**`

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

`**apps/my-app/ingress.yaml**`

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

1. Add the hostname to `infra/30-cloudflared/config.yaml`:

```yaml
ingress:
  - hostname: hello.tweak.codes
    service: http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
  - hostname: grafana.tweak.codes
    service: http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
  - hostname: my-app.tweak.codes       # ← add this
    service: http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80
  - service: http_status:404
```

1. Add DNS in Cloudflare:

```bash
cloudflared tunnel route dns homelab my-app.tweak.codes
```

1. Commit and push everything:

```bash
git add apps/my-app/ infra/30-cloudflared/config.yaml
git commit -m "feat: add my-app"
git push origin main
```

Argo CD detects the new `apps/my-app/` directory within 3 minutes and deploys it.

### App Using a Helm Chart

If your app has a community Helm chart, use `infra/` instead of `apps/` and use the
Kustomize `helmCharts` approach. Look at `infra/20-ingress-nginx/kustomization.yaml`
as a template. Create `infra/NN-my-app/kustomization.yaml` with:

```yaml
helmCharts:
  - name: my-chart
    repo: https://charts.example.com
    version: 1.2.3
    releaseName: my-app
    namespace: my-app
    valuesFile: values.yaml
    includeCRDs: true   # add if the chart has CRDs
```

### App That Needs a Secret

If your app needs a password or API key:

1. Create a plain `SopsSecret` YAML file (locally, never commit this):

```yaml
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: my-app-secret
  namespace: my-app
spec:
  secretTemplates:
    - name: my-app-secret
      stringData:
        API_KEY: "my-actual-api-key-here"
```

1. Encrypt it on the homelab host:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
sops --encrypt \
  --age age1p6z3qj3swz7g6c5qtwtyuzvm7nvxxjlvmuk8mnk00zc83yazpp7q4r0fpj \
  my-app-secret.yaml > secrets/my-app/my-app-secret.enc.yaml
```

1. Create `secrets/my-app/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - my-app-secret.enc.yaml
```

1. Reference the secret in your Deployment:

```yaml
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: my-app-secret
        key: API_KEY
```

1. Commit and push `secrets/my-app/`. Argo CD creates a `secret-my-app` application.
  The sops-secrets-operator decrypts it and creates the Kubernetes Secret.

---

## Day-to-Day Operations

### See the state of all apps

```bash
kubectl -n argocd get applications --sort-by=.metadata.name \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

### Force a sync immediately (instead of waiting 3 minutes)

```bash
kubectl -n argocd patch application app-hello \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"prune":true}}}'
```

### See logs for a pod

```bash
kubectl -n hello get pods                    # find the pod name
kubectl -n hello logs hello-xxxxx-yyyyy      # see its logs
```

### See why a pod is crashing

```bash
kubectl -n hello describe pod hello-xxxxx-yyyyy
```

### Restart an app

```bash
kubectl -n hello rollout restart deployment/hello
```

### Check that a certificate was issued

```bash
kubectl get certificates -A
# READY=True means the cert is valid
```

### Force Argo CD to re-read from Git immediately

```bash
kubectl -n argocd annotate application app-hello \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

## The Bootstrap Sequence (What You'd Do on a Fresh Cluster)

If you ever need to rebuild from scratch:

```bash
# 1. Install k3s (disable servicelb and traefik in one go)
# Then edit /etc/systemd/system/k3s.service to add:
# '--disable' 'traefik'
# Restart: sudo systemctl restart k3s

# 2. Install Argo CD (manually, one time)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Tell Argo CD to manage itself from Git
kubectl apply -f bootstrap/argocd/install.yaml

# 4. Tell Argo CD to manage the ApplicationSets from Git
kubectl apply -f bootstrap/argocd/root-app.yaml

# 5. Create the SOPS age key Secret (the one thing not in Git)
kubectl -n sops-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt

# 6. Create the Cloudflare tunnel credentials Secret
kubectl -n cloudflared create secret generic cloudflared-credentials \
  --from-file=credentials.json=$HOME/.cloudflared/<tunnel-id>.json
# (This will eventually be replaced by the SOPS-encrypted secret in Git)

# 7. Wait. Argo CD discovers all apps from Git and deploys everything automatically.
```

---

## Common Questions

**Why are the infra folders numbered?**
The numbers (10, 20, 28...) control the order in which Argo CD syncs them. cert-manager
(10) must be running before ingress-nginx (20) validates Ingress resources, which must
be running before cloudflared (30) can route traffic. The numbers become sync waves.

**What is `includeCRDs: true`?**
Some Helm charts (like kube-prometheus-stack and sops-secrets-operator) ship new
Kubernetes resource types (called Custom Resource Definitions or CRDs). These must
be installed before any resources of those types can be created. `includeCRDs: true`
tells Kustomize to ask Helm to include the CRD definitions in its rendered output.
Without it, Argo CD tries to create `PrometheusRule` resources before Kubernetes even
knows what a `PrometheusRule` is, and fails.

**What is `ServerSideApply=true`?**
A safer way for Argo CD to apply changes to the cluster. Instead of the client
computing the diff, the Kubernetes server does it. This reduces conflicts when
Kubernetes has added its own default values to resources.

**What is `CreateNamespace=true`?**
Argo CD will create the namespace if it doesn't exist before deploying resources into
it. Without this, if the namespace doesn't exist, the sync fails.

**Why does infra-45-loki sometimes show OutOfSync?**
Kubernetes adds a `volumeMode: Filesystem` field to the Loki StatefulSet's storage
spec after creation. This field isn't in the Helm chart template. We added an
`ignoreDifferences` rule to tell Argo CD to ignore this specific field. It's cosmetic
and doesn't affect how Loki works.

**What happens if I delete an Argo CD application?**
Because the AppSet has `finalizers: resources-finalizer.argocd.argoproj.io`, deleting
an Application also deletes all the Kubernetes resources it manages (pods, services,
namespaces, etc.). This is intentional — it keeps the cluster clean. The root app
(`homelab-staging-root`) does NOT have a finalizer, so deleting it won't cascade-delete
all the AppSets.

**Why is the Grafana admin password `changeme-grafana-admin` in plain YAML?**
It's a known TODO. The correct fix is to encrypt it with SOPS and reference it as a
secret. For now it works but it's not good practice.