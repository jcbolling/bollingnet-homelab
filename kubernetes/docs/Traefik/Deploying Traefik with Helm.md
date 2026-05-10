# Deploying Traefik with Helm

This guide walks through deploying Traefik as an ingress controller on Kubernetes using the official Helm chart, including dashboard access and routing other applications through the proxy.

## Prerequisites

- A running Kubernetes cluster
- `kubectl` configured to talk to your cluster
- Helm installed (`brew install helm` or see [helm.sh](https://helm.sh))

---

## How Traefik Routes Traffic

Before diving into configuration, it helps to understand the components Traefik uses to route traffic. Every request passes through these four stages in order:

### Entrypoints

The first thing traffic hits. These are Traefik's network listeners — essentially just a port that Traefik is watching. In this setup there are two:

- `web` — listens on port 80, configured to immediately redirect everything to `websecure`
- `websecure` — listens on port 443, handles TLS termination

### Routers (IngressRoutes)

Once traffic arrives on an entrypoint, Traefik evaluates it against all registered routers. A router is a set of rules — typically matching on hostname and/or path — that decides where the request should go. In Kubernetes these are defined as `IngressRoute` resources. If no router matches, Traefik returns a 404.

### Middlewares

Before a matched request is forwarded to a service, it can pass through one or more middlewares. These transform or redirect the request in some way. Middlewares are attached to routers, not entrypoints or services.

### Services

Once a router has matched a request and any middlewares have fired, the request is forwarded to a service. The service is what actually receives the traffic — either a Kubernetes `Service` resource pointing at your application pods, or a special built-in like `api@internal` which backs the Traefik dashboard.

### The Full Picture

```
Browser request
    ↓
Entrypoint (web / websecure)
    ↓
Router (IngressRoute — does the host/path match?)
    ↓
Middleware (transform or redirect the request)
    ↓
Service (forward to a Kubernetes Service → Pod)
```

Every request follows this chain in order. If it falls through at any stage — no matching router, no registered service — Traefik returns a 404.

---

## Add the Traefik Helm Repository

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

## Create the Traefik Namespace

```bash
kubectl create namespace traefik
```

## Configure helm-values.yaml

Create a `helm-values.yaml` file with the following contents, replacing placeholder values with your own:

```yaml
# helm-values.yaml

# Use the helm chart's built-in support for creating an IngressRoute for the
# Traefik dashboard. Requests matching the host and path prefix are served by
# Traefik's built-in api@internal service.
ingressRoute:
  dashboard:
    enabled: true
    # Match requests to the dashboard and API paths. The /api prefix is needed
    # because the dashboard UI makes backend calls to /api/... to populate itself.
    matchRule: Host(`traefik.YOUR-DOMAIN.com`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
    # Register this route on both entrypoints so it matches both the initial
    # HTTP request and the HTTPS request that follows the port 80 redirect.
    entryPoints:
      - web
      - websecure
    # Reference the TLS secret created by cert-manager for the dashboard host.
    tls:
      secretName: tls-traefik-dashboard
    # Apply the dashboard-redirect middleware to redirect /dashboard to /dashboard/
    middlewares:
      - name: dashboard-redirect
        namespace: traefik

ports:
  web:
    asDefault: true
    port: 80
    expose:
      default: true
    exposedPort: 80
    http:
      redirections:
        # Redirect all HTTP traffic on port 80 to HTTPS on port 443. This fires
        # before any IngressRoute matching, so every request is upgraded to HTTPS
        # before routing decisions are made.
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    port: 443
    expose:
      default: true
    exposedPort: 443
    tls:
      enabled: true

providers:
  # Tell Traefik to watch the cluster for Kubernetes Gateway API resources
  # (Gateway, HTTPRoute, etc.) and use them as a source of routing config.
  kubernetesGateway:
    enabled: true
  kubernetesCRD:
    # Allow IngressRoutes in one namespace to reference Services in another.
    # Disable this in production and co-locate IngressRoutes with their apps instead.
    allowCrossNamespace: true

gateway:
  namespace: traefik # Setting explicitly but this should automatically align with the namespace where Traefik is deployed
  listeners:
    # Create a Gateway listener on port 80 that accepts traffic from all
    # namespaces in the cluster, allowing any namespace to define HTTPRoutes
    # that attach to this Gateway.
    web:
      port: 80
      namespacePolicy:
        from: All
```

## Configure traefik-dashboard-routing.yaml

Create a separate `traefik-dashboard-routing.yaml` file for the supplementary routing resources. These are managed separately from `helm-values.yaml` because they are raw Kubernetes manifests that can be applied independently with `kubectl` without triggering a Helm upgrade.

```yaml
# traefik-dashboard-routing.yaml

---
# Redirect /dashboard → /dashboard/
# The Traefik dashboard requires a trailing slash. This middleware catches
# requests to /dashboard with no trailing slash and issues a permanent
# redirect. The $ anchor ensures /dashboard/something is not affected.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: dashboard-redirect
  namespace: traefik
spec:
  redirectRegex:
    regex: ^https://traefik\.YOUR-DOMAIN\.com/dashboard$
    replacement: https://traefik.YOUR-DOMAIN.com/dashboard/
    permanent: true

---
# Redirect bare host → /dashboard/
# This middleware catches requests to the root path and redirects to the
# dashboard, so browsing to traefik.YOUR-DOMAIN.com lands on the dashboard
# rather than a 404.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: root-redirect
  namespace: traefik
spec:
  redirectRegex:
    regex: ^https://traefik\.YOUR-DOMAIN\.com/?$
    replacement: https://traefik.YOUR-DOMAIN.com/dashboard/
    permanent: true

---
# IngressRoute to catch the bare host and apply the root-redirect middleware.
# This is a separate IngressRoute from the dashboard one in helm-values.yaml
# because the dashboard IngressRoute only matches /dashboard and /api prefixes —
# it would never see a bare / request, so there is nothing to attach the
# middleware to.
#
# The match rule uses Host() without a path condition so that any unmatched
# path on this host falls through to the redirect, rather than returning a 404.
# Traefik evaluates rules by specificity, so the more specific /dashboard and
# /api rules in the dashboard IngressRoute always win.
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-root-redirect
  namespace: traefik
spec:
  entryPoints:
    - web
    - websecure
  routes:
    - match: Host(`traefik.YOUR-DOMAIN.com`)
      kind: Rule
      middlewares:
        - name: root-redirect
      # api@internal is Traefik's built-in service that backs the dashboard.
      # A service is required by the IngressRoute spec even though this route
      # only exists to fire a redirect and will never actually forward traffic.
      services:
        - name: api@internal
          kind: TraefikService
```

> **Note:** Always set `namespace` in the `metadata` of every resource in this file. Without it, `kubectl apply` will deploy resources to whatever your current default namespace is, creating stray resources that are difficult to track down.

> **Note:** Do not set `namespace` on middleware references inside an `IngressRoute` (i.e. under `routes[].middlewares[]`). Traefik ignores it in cross-provider context and will log warnings.

## Install Traefik

Apply the routing resources first so the middlewares exist before the Helm chart creates the dashboard `IngressRoute` that references them:

```bash
kubectl apply -f traefik-dashboard-routing.yaml
helm install traefik traefik/traefik \
  --namespace traefik \
  --values helm-values.yaml
```

## Upgrade After Config Changes

If you modify `helm-values.yaml`, apply the changes with:

```bash
helm upgrade traefik traefik/traefik \
  --namespace traefik \
  --values helm-values.yaml
```

If you modify `traefik-dashboard-routing.yaml`, apply it directly with kubectl — no Helm upgrade needed:

```bash
kubectl apply -f traefik-dashboard-routing.yaml
```

## Accessing the Dashboard

Once deployed, browse to:

```
https://traefik.YOUR-DOMAIN.com
```

You will be redirected through the following chain:

```
http://traefik.YOUR-DOMAIN.com              → 301 (HTTP → HTTPS)
https://traefik.YOUR-DOMAIN.com             → 301 (root → /dashboard/)
https://traefik.YOUR-DOMAIN.com/dashboard   → 301 (trailing slash redirect)
https://traefik.YOUR-DOMAIN.com/dashboard/  → 200 dashboard UI
```

## Troubleshooting

Watch Traefik logs in real time, optionally limiting to recent output:

```bash
kubectl logs -n traefik deployment/traefik -f --since=1h
```

Check the status of routing resources:

```bash
kubectl describe ingressroute -n traefik
kubectl describe middleware -n traefik
```

If you see unexpected 404s or routing errors, check for stray resources created in the wrong namespace:

```bash
kubectl get ingressroute,middleware -A
```

---

## Deploying an Application Behind Traefik

Each application needs three Kubernetes resources: a `Deployment`, a `Service`, and an `IngressRoute`. These can all live in a single manifest file.

### Example: NGINX

```yaml
# nginx.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nginx
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:latest
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: nginx
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: nginx
  namespace: nginx
spec:
  entryPoints:
    - websecure  # Only websecure is needed — all HTTP traffic is redirected to HTTPS by Traefik
  routes:
    - match: Host(`nginx.YOUR-DOMAIN.com`)
      kind: Rule
      services:
        - name: nginx
          port: 80
```

> **Note:** Do not set `namespace` on service references inside an `IngressRoute` (i.e. under `routes[].services[]`) unless you have `allowCrossNamespace: true` configured and the service genuinely lives in a different namespace. Traefik requires the service to be in the same namespace as the `IngressRoute` by default, and will log errors if a namespace is specified that doesn't match.

Apply it with:

```bash
kubectl apply -f nginx.yaml
```

Because the `IngressRoute` is a Kubernetes custom resource that Traefik watches continuously, **no Helm upgrade is required** when adding or changing application routes. Traefik picks up the new IngressRoute immediately.

### How Traffic Flows

```
Browser → https://nginx.YOUR-DOMAIN.com (port 443, HTTPS)
            ↓
          Traefik terminates TLS, matches IngressRoute
            ↓
          nginx Service → nginx Pod on port 80 (plain HTTP, cluster-internal)
```

TLS is terminated at Traefik. Traffic between Traefik and your application pods travels over the cluster's internal network unencrypted, which is standard practice. Your application does not need to handle TLS.

---

## Production Considerations

| Topic | Homelab | Production |
|---|---|---|
| `allowCrossNamespace` | Fine to enable | Disable; co-locate IngressRoute with app |
| TLS certificates | Self-signed is acceptable | Configure a cert resolver (e.g. Let's Encrypt) |
| Dashboard exposure | Expose freely | Restrict with authentication middleware |
| Namespace watching | Watch all namespaces | Restrict to known namespaces via `providers.kubernetesCRD.namespaces` |