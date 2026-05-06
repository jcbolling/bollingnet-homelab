# Deploying Traefik with Helm

This guide walks through deploying Traefik as an ingress controller on Kubernetes using the official Helm chart, including dashboard access and routing other applications through the proxy.

## Prerequisites

- A running Kubernetes cluster
- `kubectl` configured to talk to your cluster
- Helm installed (`brew install helm` or see [helm.sh](https://helm.sh))

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

extraObjects:
  # Redirect /dashboard → /dashboard/
  # The Traefik dashboard requires a trailing slash. This middleware catches
  # requests to /dashboard with no trailing slash and issues a permanent
  # redirect. The $ anchor ensures /dashboard/something is not affected.
  - apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
      name: dashboard-redirect
      namespace: traefik
    spec:
      redirectRegex:
        regex: ^https://traefik\.YOUR-DOMAIN\.com/dashboard$
        replacement: https://traefik.YOUR-DOMAIN.com/dashboard/
        permanent: true

  # Redirect bare host → /dashboard/
  # This middleware catches requests to the root path and redirects to the
  # dashboard, so browsing to traefik.YOUR-DOMAIN.com lands on the dashboard
  # rather than a 404.
  - apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
      name: root-redirect
      namespace: traefik
    spec:
      redirectRegex:
        regex: ^https://traefik\.YOUR-DOMAIN\.com/?$
        replacement: https://traefik.YOUR-DOMAIN.com/dashboard/
        permanent: true

  # IngressRoute to catch the bare host and apply the root-redirect middleware.
  # This is a separate IngressRoute from the dashboard one above because the
  # dashboard IngressRoute only matches /dashboard and /api prefixes — it would
  # never see a bare / request, so there is nothing to attach the middleware to.
  - apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      name: traefik-root-redirect
      namespace: traefik
    spec:
      entryPoints:
        - web
        - websecure
      routes:
        - match: Host(`traefik.YOUR-DOMAIN.com`) && Path(`/`)
          kind: Rule
          middlewares:
            - name: root-redirect
              namespace: traefik
          # api@internal is Traefik's built-in service that backs the dashboard.
          # A service is required by the IngressRoute spec even though this route
          # only exists to fire a redirect and will never actually forward traffic.
          services:
            - name: api@internal
              kind: TraefikService
```

## Install Traefik

```bash
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

## Accessing the Dashboard

Once deployed, browse to:

```
https://traefik.YOUR-DOMAIN.com
```

You will be redirected through the following chain:

```
http://traefik.YOUR-DOMAIN.com         → 301 (HTTP → HTTPS)
https://traefik.YOUR-DOMAIN.com        → 301 (root → /dashboard/)
https://traefik.YOUR-DOMAIN.com/dashboard/  → 200 dashboard UI
```

> **Note:** If you have not configured a TLS certificate resolver, Traefik will use a self-signed certificate and your browser will show a security warning. You can bypass this for internal/homelab use or configure a cert resolver (e.g. Let's Encrypt) for a trusted certificate.

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
          namespace: nginx
          port: 80
```

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