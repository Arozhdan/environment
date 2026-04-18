# How this homelab GitOps setup works (internal guide)

This document is meant for **you**, not for automation. It explains the whole system in plain language: what each piece does, why it is there, and what you could have chosen instead.

---

## 1. What problem are we solving?

You have a **mini PC** at home running **Kubernetes** (k3s). You want:

- A **single place** (this Git repository) that describes *how the cluster should look*.
- Changes to the cluster to happen through **normal Git work** (branches, pull requests, review), not by SSH-ing in and running commands by hand.
- **Traditional** in-cluster networking (Ingress, certificates) so the same ideas work later in a **cloud “prod”** cluster.

That pattern is called **GitOps**: Git is the source of truth; a controller in the cluster **reconciles** reality to match Git.

**Tool that does that here:** **Argo CD**.

---

## 2. Big picture: how traffic and changes flow

### 2.1 When you change something

1. You edit files in this repo (for example add an app under `apps/`).
2. You merge to `main` (ideally via a PR).
3. **Argo CD** notices the new commit, reads the manifests, and applies them to the cluster.
4. The cluster moves toward the **desired state** described in Git.

You generally **do not** run `kubectl apply` for day-to-day changes. Exceptions: rare **bootstrap** steps or one-off emergencies.

### 2.2 When someone visits your website

For public services, the rough path is:

**Internet → Cloudflare → Cloudflare Tunnel (cloudflared) → Ingress controller → your Service → your Pods**

- **Cloudflare** terminates TLS from the public internet at their edge (their certificate).
- **Cloudflare Tunnel** (`cloudflared`) is a small program running **inside your cluster** that maintains an outbound connection to Cloudflare. You do **not** need to open ports on your home router for HTTPS.
- Inside the cluster, traffic hits **ingress-nginx**, which reads **Ingress** objects and routes HTTP to the right **Service**.

For **TLS certificates for your own domain** (Let’s Encrypt), this repo uses **cert-manager** with **HTTP-01** challenges. The certificate is used between the client and your ingress (and/or between tunnel and ingress, depending on how you terminate TLS). The important idea: **no Cloudflare API tokens are required inside the cluster** for ACME, which keeps the Kubernetes config portable.

**Alternative (not chosen for cluster config):** **DNS-01** with Cloudflare API. It works well but ties automation to Cloudflare credentials in the cluster. You asked for **traditional** Kubernetes networking without Cloudflare-specific controllers.

---

## 3. The main tools (what they are, in one paragraph each)

### 3.1 Kubernetes (and k3s)

**Kubernetes** is a system that runs **containers** (usually Docker/OCI images) and connects them with **networking**, **storage**, and **configuration**.

**k3s** is a lightweight distribution of Kubernetes, popular on small servers and homelabs. For this document, “Kubernetes” and “k3s” mean the same idea: you declare **desired state**; the control plane makes it so.

### 3.2 Git

**Git** tracks changes to files over time. For GitOps, Git is also your **audit log** and **approval workflow** (PRs).

### 3.3 Argo CD

**Argo CD** is an application that runs **inside the cluster**. It:

- Connects to your **Git repository**
- Compares what Git says vs what the cluster has
- Applies differences (sync)

You use the Argo CD UI or CLI to see **health** and **sync status** of each application.

**Alternative:** **Flux CD**. Also excellent. Argo CD is very UI-friendly and widely used; either can implement GitOps. This repo is built around Argo CD.

### 3.4 Application and ApplicationSet

Argo CD’s unit of work is an **Application**: “sync this path in Git to this cluster/namespace.”

An **ApplicationSet** is a **template** that generates many Applications automatically—for example, “one Application per folder under `infra/`.” That avoids maintaining a hand-written list.

### 3.5 Kustomize

**Kustomize** builds Kubernetes YAML from a folder:

- Base manifests
- Patches
- Generated ConfigMaps
- Optional: **Helm charts** inlined as part of the build (`helmCharts` in `kustomization.yaml`)

Argo CD is configured so Kustomize can run **with Helm chart inflation** enabled (see `bootstrap/argocd/values.yaml`).

**Alternative:** **Helmfile**, **Terraform Kubernetes provider**, or raw scripts. Kustomize + Helm per-component keeps each component self-contained and works well with Argo CD.

### 3.6 Helm

**Helm** is a package manager for Kubernetes. A **chart** packages templates and default values for complex software (ingress-nginx, Prometheus, etc.).

This repo often uses **Helm via Kustomize** so each `infra/<something>/` folder stays one Argo Application.

### 3.7 ingress-nginx

**ingress-nginx** is an **Ingress controller**: the component that makes **Ingress** resources actually route HTTP/HTTPS traffic inside the cluster.

**Alternative:** **Traefik**, **Cilium Gateway**, **Gateway API** controllers. ingress-nginx is the common “traditional” choice.

### 3.8 cert-manager

**cert-manager** requests and renews TLS certificates automatically. It uses **Issuers** / **ClusterIssuers** to talk to Let’s Encrypt (or other CAs).

This repo uses **HTTP-01** challenges so certificates can validate via HTTP through your ingress.

### 3.9 Cloudflare Tunnel (cloudflared)

**cloudflared** connects your cluster to **Cloudflare** without exposing your home IP directly and without port-forwarding.

It is the **only** Cloudflare-specific workload in the “traditional networking” story: everything else is standard Kubernetes objects.

**Alternative for prod later:** a cloud load balancer with a public IP, or NodePort, depending on provider.

### 3.10 Tailscale (context only)

**Tailscale** builds a private network between your devices. It is **not** the data plane for public website visitors in this design; it is mainly how **you** reach the cluster safely (e.g. `kubectl`, Argo UI) from your laptop.

### 3.11 SOPS and age

**SOPS** encrypts YAML files in Git so secrets are not stored in plaintext.

**age** is a modern encryption tool. SOPS commonly uses age keys.

You encrypt files on your laptop; Git stores ciphertext; something in the cluster must decrypt.

### 3.12 sops-secrets-operator

**sops-secrets-operator** watches **SopsSecret** resources and creates normal Kubernetes **Secret** objects from encrypted content.

**Alternative:** **Sealed Secrets** (Bitnami). It is popular, but sealing is tied to cluster keys in ways that are awkward when you later add a second “prod” cluster. **SOPS + age** keeps the *same* encryption approach portable if you manage keys carefully.

**Alternative:** **External Secrets Operator** pulling from Vault/1Password. Great for teams; more moving parts for a homelab.

---

## 4. What’s in this repository (mental model)

Think of the repo as **three layers**:

1. **Bootstrap** (`bootstrap/argocd/`): how Argo CD is installed/self-managed and how the top-level **ApplicationSets** are registered.
2. **Platform** (`infra/`): cluster infrastructure—ingress, certs, tunnel, observability, operators.
3. **Apps** (`apps/`): things you actually use—websites, services, demos.

There is also **`secrets/`**: encrypted “secret apps” synced by GitOps once the operator is ready.

---

## 5. Why the layout looks like this

### 5.1 Numeric prefixes (`10-`, `20-`, …)

Folders under `infra/` are named like `10-cert-manager`, `20-ingress-nginx`, etc.

**Why:** humans can see ordering at a glance. Some dependencies are also **co-located** into the same app to avoid fragile cross-app ordering on first install (for example, **ClusterIssuers** live next to **cert-manager** in the same Kustomize build).

**Important nuance:** Argo CD **sync waves** on separate Applications help, but they are not a perfect guarantee for *every* edge case on a brand-new cluster. That is why the docs describe a **short staged rollout** on first bring-up (infra healthy → operator key → encrypted secrets → workloads).

### 5.2 One Argo Application per folder

The **ApplicationSet** generates one Argo **Application** per subdirectory. Adding a new component is usually: **create a new folder** + merge.

**Alternative:** one giant Helm umbrella chart. Faster to start, harder to maintain and review.

### 5.3 `secrets/` as its own ApplicationSet

Encrypted secrets live under `secrets/<app>/` and are synced by `clusters/homelab-staging/appset-secrets.yaml`.

**Why:** keeps secret material out of `infra/` and lets CI enforce “no plaintext secrets except allowed examples.”

### 5.4 Cloudflare tunnel credentials

The tunnel JSON is sensitive. The intended flow is:

- Encrypt with SOPS
- Store ciphertext in Git
- Let the operator materialize a Kubernetes `Secret`

The repo includes **examples only** (`*.example.yaml`) for shape/documentation, not real secrets.

---

## 6. Observability: what you installed and why

This repo includes:

- **kube-prometheus-stack**: Prometheus + Grafana + Kubernetes monitoring basics
- **Loki**: log storage
- **Grafana Alloy**: agents that forward logs to Loki

**Why:** when something breaks, you want **metrics** (CPU, restarts) and **logs** (why it crashed) without guessing.

**Alternative:** SaaS monitoring (Datadog, Grafana Cloud). Great, but costs money and sends data off-cluster.

---

## 7. CI in GitHub Actions (what it proves)

The workflow renders Kustomize builds and runs checks like **kubeconform** (schema validation) and **yamllint**.

**What it does not replace:** actually running workloads in a real cluster. It catches a lot of typos and broken YAML early.

---

## 8. Alternatives summary (quick table)

| Area | Chosen | Reason | Common alternative |
|------|--------|--------|---------------------|
| GitOps engine | Argo CD | Strong UI, widely documented | Flux |
| App generator | ApplicationSet | Less manual bookkeeping | Hand-written app-of-apps |
| Templating | Kustomize + Helm | Clear per-component folders | Helmfile / raw Helm only |
| Ingress | ingress-nginx | Traditional Ingress model | Traefik, Gateway API |
| Certificates | cert-manager + HTTP-01 | No DNS API tokens in-cluster | DNS-01 (Cloudflare API) |
| Public exposure | Cloudflare Tunnel | No router port opening | LB / port forward |
| Secrets in Git | SOPS + age + operator | Portable, Git-native | Sealed Secrets, External Secrets |
| Logs/metrics | Prometheus + Loki + Alloy | Self-hosted visibility | SaaS monitoring |

---

## 9. How you operate this day-to-day (non-DevOps checklist)

### 9.1 Normal change

1. Create a branch
2. Edit manifests
3. Open PR
4. Merge
5. Watch Argo CD sync

### 9.2 When something is “OutOfSync”

It means Git and the cluster disagree. Common causes:

- Someone changed the cluster by hand (avoid)
- A secret is missing
- A chart version changed behavior

Argo CD will show **diffs**. The goal is to return to “Git says X, cluster matches X.”

### 9.3 When you add a new app

Usually:

1. Create `apps/<name>/` with a `kustomization.yaml`
2. Merge
3. Argo creates a new Application automatically (via ApplicationSet)

---

## 10. First-time bring-up (human sequence)

This is the practical order that avoids races:

1. Ensure Argo CD can read the Git repo (HTTPS or SSH—**must match** what you put in manifests).
2. Apply bootstrap manifests (`bootstrap/argocd/install.yaml`, then ApplicationSets).
3. Let core infra reconcile (ingress, cert-manager, operators).
4. Create the **age** private key Secret expected by `sops-secrets-operator` (see `docs/secrets.md`).
5. Add encrypted secret apps under `secrets/` as needed.
6. Confirm apps like `hello` and `cloudflared` become healthy.

If you try to apply encrypted secrets before the operator exists, you can get transient failures. That is normal; it’s why the staged rollout exists.

---

## 11. What “prod later” means for this repo

Your homelab is treated like **staging**: safe place to learn.

When you later use a managed Kubernetes cluster for **prod**, the idea is:

- Keep the same repo layout (`infra/`, `apps/`)
- Add a second cluster configuration under `clusters/` (this repo already has a `clusters/prod/` scaffold for thinking it through)
- Swap **edge** components (tunnel vs cloud load balancer) without rewriting the whole app manifests

---

## 12. Glossary (short)

- **Manifest**: YAML describing Kubernetes objects.
- **Sync**: Apply desired state from Git to the cluster.
- **Reconcile**: Continuously work toward desired state.
- **Ingress**: HTTP routing rules inside the cluster.
- **Namespace**: A logical partition of resources (like a folder).
- **Operator**: A controller that watches custom resources and acts on them.
- **Helm chart**: Packaged Kubernetes templates for an app.
- **Kustomize overlay**: A folder that patches/extends base YAML.

---

## 13. Where to read next (technical runbooks)

- `README.md` — operator-focused quickstart
- `docs/PREREQS.md` — tools to install on your laptop
- `docs/secrets.md` — SOPS + age + operator flow
- `docs/hardening.md` — maturity checklist (SSO, backups, policies)
- `infra/README.md` — what each infra folder is for

---

If you want this turned into a printed PDF or a shorter 1-page “cheat sheet,” say which format you prefer.
