# Deploying ArgoCD with Helm

## Prerequisites

- A running Kubernetes cluster
- `kubectl` configured and connected to your cluster
- Traefik installed as your ingress controller
- cert-manager installed for TLS certificate management

---

## 1. Install ArgoCD

Create the ArgoCD namespace and apply the official installation manifest:

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Verify all pods are running before proceeding:

```bash
kubectl get pods -n argocd
```

---

## 2. Install the ArgoCD CLI

The ArgoCD CLI is used to manage applications, retrieve the initial password, and interact with the ArgoCD API from your terminal.

### macOS

```bash
brew install argocd
```

### Linux

```bash
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64
```

### Windows

```powershell
winget install ArgoProj.ArgoCD
```

Verify the installation:

```bash
argocd version --client
```

---

## 3. Create a TLS Certificate

Create a `Certificate` resource so cert-manager provisions a TLS certificate for your ArgoCD domain. Save this as `argocd-certificate.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-server
  namespace: argocd
spec:
  secretName: tls-argocd-server
  issuerRef:
    name: your-cluster-issuer   # replace with your ClusterIssuer name
    kind: ClusterIssuer
  dnsNames:
    - argocd.int.example.com    # replace with your domain
```

Apply it:

```bash
kubectl apply -f argocd-certificate.yaml
```

Verify the certificate is ready:

```bash
kubectl get certificate -n argocd
```

Wait until the `READY` column shows `True` before continuing.

---

## 4. Create the IngressRoute

ArgoCD requires two routing rules — one for standard browser traffic and one for gRPC traffic used by the ArgoCD CLI.

Save this as `argocd-ingressroute.yaml`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`argocd.int.example.com`)
      priority: 10
      services:
        - name: argocd-server
          port: 80
    - kind: Rule
      match: Host(`argocd.int.example.com`) && Header(`Content-Type`, `application/grpc`)
      priority: 11
      services:
        - name: argocd-server
          port: 80
          scheme: h2c
  tls:
    secretName: tls-argocd-server  # must match spec.secretName in your Certificate
```

**Why two routes?**

| Rule | Priority | Purpose |
|------|----------|---------|
| `Host(...)` | 10 | Handles browser/UI traffic over HTTP/1.1 |
| `Host(...) && Header(Content-Type, application/grpc)` | 11 | Handles ArgoCD CLI traffic over HTTP/2 (gRPC) |

The gRPC rule has a higher priority so it matches before the generic rule. The `scheme: h2c` tells Traefik to forward gRPC requests to the backend using cleartext HTTP/2, which gRPC requires.

Apply it:

```bash
kubectl apply -f argocd-ingressroute.yaml
```

---

## 5. Fix: Too Many Redirects

### The Problem

After setting up the IngressRoute you may encounter an `ERR_TOO_MANY_REDIRECTS` error in your browser. This is caused by a redirect loop between Traefik and ArgoCD:

```
Browser          Traefik (TLS)        ArgoCD pod
   │                  │                    │
   │──① HTTPS ───────>│                    │
   │                  │──② HTTP ──────────>│
   │                  │                    │ "I only speak HTTPS!"
   │                  │<──③ 301 → HTTPS ───│
   │<─④ passes 301 ───│                    │
   │                  │                    │
   └──⑤ retries HTTPS ──────────────────── (back to step ①)
                      ↑______ loops forever ______↑
```

Traefik terminates TLS and forwards plain HTTP to the ArgoCD pod. ArgoCD sees an unencrypted request, assumes it is insecure, and issues a `301` redirect to HTTPS. Traefik passes the redirect back to the browser, which retries over HTTPS — and the loop repeats until the browser gives up.

### The Fix

Tell ArgoCD to run in insecure mode so it stops enforcing HTTPS itself, trusting that Traefik handles TLS termination.

Edit the `argocd-cmd-params-cm` ConfigMap:

```bash
kubectl edit configmap argocd-cmd-params-cm -n argocd
```

Add the `data` block if it does not already exist:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  server.insecure: "true"   # add this
```

Restart the ArgoCD server to pick up the change:

```bash
kubectl rollout restart deployment argocd-server -n argocd
```

After the rollout completes, traffic flows correctly:

```
Browser          Traefik (TLS)        ArgoCD pod
   │                  │                    │
   │──① HTTPS ───────>│                    │
   │                  │──② HTTP ──────────>│
   │                  │                    │ "HTTP is fine, Traefik handles TLS"
   │                  │<──③ 200 OK ────────│
   │<─④ page loads ───│                    │

          ArgoCD loads successfully ✅
```

---

## 6. Verify the Installation

Check that all ArgoCD pods are healthy:

```bash
kubectl get pods -n argocd
```

Retrieve the initial admin password using the ArgoCD CLI:

```bash
argocd admin initial-password -n argocd
```

Alternatively, retrieve it directly with kubectl:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d
```

Log in at `https://argocd.int.example.com` with username `admin` and the password above.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `ERR_TOO_MANY_REDIRECTS` | ArgoCD enforcing HTTPS behind Traefik | Set `server.insecure: "true"` in `argocd-cmd-params-cm` |
| Certificate not ready | cert-manager issuer misconfigured | Check `kubectl describe certificate -n argocd` |
| ArgoCD CLI errors (`transport: error while dialing`) | gRPC IngressRoute rule missing | Add the `scheme: h2c` rule with `priority: 11` |
| 404 on the domain | IngressRoute not applied or wrong namespace | Verify with `kubectl get ingressroute -n argocd` |