# Deploy Authentik with Helm

Authentik is an open-source identity provider supporting OAuth2, OIDC, SAML, LDAP, and proxy authentication. This document covers deploying Authentik using the official Helm chart, with options for a quick test deployment using bundled dependencies or a production-oriented deployment using dedicated PostgreSQL and Redis instances.

---

## Prerequisites

- Kubernetes cluster with Helm installed
- Traefik ingress controller
- cert-manager with a working `ClusterIssuer`
- `authentik` namespace created

```bash
kubectl create namespace authentik
```

---

## Option A: Quick Start (Bundled PostgreSQL and Redis)

The Authentik Helm chart includes optional bundled PostgreSQL and Redis deployments suitable for testing and evaluation. These are **not recommended for production** — they are single-replica with no persistent storage guarantees and no HA.

### `values.yaml`

```yaml
# Authentik Helm values
# Chart: authentik/authentik
# https://artifacthub.io/packages/helm/authentik/authentik
#
# helm install authentik authentik/authentik --namespace authentik --values values.yaml

authentik:
  secret_key: "<generate with: openssl rand -base64 60>"
  log_level: info

  email:
    host: "smtp-relay.example.com"
    port: 587
    use_tls: true
    use_ssl: false
    timeout: 30
    from: authentik@example.com

postgresql:
  enabled: true

redis:
  enabled: true

server:
  ingress:
    enabled: true
    ingressClassName: traefik
    annotations:
      cert-manager.io/cluster-issuer: <your-cluster-issuer>
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
    hosts:
      - authentik.example.com
    tls:
      - secretName: authentik-tls
        hosts:
          - authentik.example.com

  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi

worker:
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi
```

> **Note:** With bundled dependencies, `secret_key` is set directly in the values file. For production, use a Kubernetes secret instead — see Option B.

### Deploy

```bash
helm repo add authentik https://charts.goauthentik.io
helm repo update

helm upgrade --install authentik authentik/authentik \
  --namespace authentik \
  --values values.yaml
```

---

## Option B: Production Deployment (Dedicated PostgreSQL and Redis)

This approach uses externally managed PostgreSQL and Redis instances, with all sensitive values stored in Kubernetes secrets rather than in the values file. The values file is safe to commit to version control as-is.

### Prerequisites

- A dedicated PostgreSQL cluster with a database and user created for Authentik — see the [PostgreSQL deployment guide](#) for details
- A dedicated Redis instance — see the [Redis deployment guide](redis-deployment.md) for details

### Create Secrets

All secrets must exist in the `authentik` namespace before deploying. Run each command as a single line to avoid shell line-continuation issues.

**Authentik secret key** — generate once and back it up somewhere safe. Losing or rotating this key invalidates all active sessions and may make encrypted data in the database unreadable:

```bash
kubectl create secret generic authentik-secret-key --namespace authentik --from-literal=secret-key="$(openssl rand -base64 60)"
```

**Redis password** — copy from the Redis namespace (Kubernetes secrets cannot be referenced cross-namespace):

```bash
REDIS_PASS=$(kubectl get secret redis-auth -n redis -o jsonpath='{.data.redis-password}' | base64 -d)
kubectl create secret generic authentik-redis-auth --namespace authentik --from-literal=redis-password=$REDIS_PASS
```

**PostgreSQL credentials** — if not already present in the `authentik` namespace, create or copy the secret containing your database connection details. The secret should have the following keys: `host`, `database`, `username`, `password`, `port`.

### `values.yaml`

```yaml
# Authentik Helm values
# Chart: authentik/authentik
# https://artifacthub.io/packages/helm/authentik/authentik
#
# helm install authentik authentik/authentik --namespace authentik --values values.yaml

authentik:
  secret_key: ""      # injected via env
  log_level: info

  postgresql:
    host: ""          # injected via env
    name: ""          # injected via env
    user: ""          # injected via env
    password: ""      # injected via env
    port: 5432

  redis:
    host: redis-master.redis.svc.cluster.local
    db: 0
    password: ""      # injected via env

  email:
    host: "smtp-relay.example.com"
    port: 587
    use_tls: true
    use_ssl: false
    timeout: 30
    from: authentik@example.com

postgresql:
  enabled: false  # using external PostgreSQL

redis:
  enabled: false  # using external Redis

server:
  ingress:
    enabled: true
    ingressClassName: traefik
    annotations:
      cert-manager.io/cluster-issuer: <your-cluster-issuer>
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
    hosts:
      - authentik.example.com
    tls:
      - secretName: authentik-tls
        hosts:
          - authentik.example.com

  env:
    - name: AUTHENTIK_SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: authentik-secret-key
          key: secret-key
    - name: AUTHENTIK_REDIS__PASSWORD
      valueFrom:
        secretKeyRef:
          name: authentik-redis-auth
          key: redis-password
    - name: AUTHENTIK_POSTGRESQL__HOST
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: host
    - name: AUTHENTIK_POSTGRESQL__NAME
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: database
    - name: AUTHENTIK_POSTGRESQL__USER
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: username
    - name: AUTHENTIK_POSTGRESQL__PASSWORD
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: password
    - name: AUTHENTIK_POSTGRESQL__PORT
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: port

  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi

worker:
  env:
    - name: AUTHENTIK_SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: authentik-secret-key
          key: secret-key
    - name: AUTHENTIK_REDIS__PASSWORD
      valueFrom:
        secretKeyRef:
          name: authentik-redis-auth
          key: redis-password
    - name: AUTHENTIK_POSTGRESQL__HOST
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: host
    - name: AUTHENTIK_POSTGRESQL__NAME
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: database
    - name: AUTHENTIK_POSTGRESQL__USER
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: username
    - name: AUTHENTIK_POSTGRESQL__PASSWORD
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: password
    - name: AUTHENTIK_POSTGRESQL__PORT
      valueFrom:
        secretKeyRef:
          name: <your-pg-secret>
          key: port

  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi
```

### Deploy

```bash
helm repo add authentik https://charts.goauthentik.io
helm repo update

helm upgrade --install authentik authentik/authentik \
  --namespace authentik \
  --values values.yaml
```

---

## Verify

```bash
# Watch pods come up — the server runs DB migrations on first boot
kubectl get pods -n authentik -w

# Tail server logs to confirm successful DB connection and migration
kubectl logs -n authentik -l app.kubernetes.io/component=server -f

# Check ingress and certificate
kubectl get ingress -n authentik
kubectl get certificate -n authentik
```

The server pod runs database migrations on first boot. Allow 30–60 seconds before expecting the pod to be ready. The worker pod may take slightly longer due to its startup probe configuration.

---

## Probe Tuning

The default probe timeout of 3 seconds may be too tight for the worker during startup, causing repeated restarts even when the worker is healthy. If you observe this, increase the timeouts:

```yaml
worker:
  startupProbe:
    exec:
      command: [ak, healthcheck]
    initialDelaySeconds: 30
    periodSeconds: 10
    failureThreshold: 60
    timeoutSeconds: 10

  livenessProbe:
    exec:
      command: [ak, healthcheck]
    initialDelaySeconds: 5
    periodSeconds: 10
    failureThreshold: 3
    timeoutSeconds: 10

  readinessProbe:
    exec:
      command: [ak, healthcheck]
    initialDelaySeconds: 5
    periodSeconds: 10
    failureThreshold: 3
    timeoutSeconds: 10
```

---

## Initial Setup

Once pods are running and the certificate is issued, complete the initial admin setup:

```
https://authentik.example.com/if/flow/initial-setup/
```

This sets the admin account password. From there, navigate to the Authentik UI to configure branding, applications, providers, and outposts.

---

## Verify Email Delivery

Exec into the server pod to send a test email:

```bash
kubectl exec -it -n authentik deployment/authentik-server -- ak test_email your@email.com
```

The task is handed off to the worker for delivery. If the worker is not ready, the command will time out — verify worker health first with `kubectl get pods -n authentik`.

---

## Integration Patterns

Authentik supports two primary integration patterns depending on the application.

### Direct OIDC/SAML Integration (preferred)

Many applications support OAuth2/OIDC or SAML natively — for these, configure an **OAuth2/OpenID Provider** or **SAML Provider** in Authentik and point the application directly at it. This is the preferred approach where supported, as authentication happens at the application layer with full protocol support.

Examples of applications that support direct integration:

- **Portainer** — OAuth2/OIDC
- **Proxmox VE** — OpenID Connect
- **Grafana** — OAuth2/OIDC
- **GitLab** — OAuth2/OIDC or SAML
- **Nextcloud** — OIDC or SAML

### Traefik Forward Auth (fallback)

For applications that have no native SSO support, Authentik's **Proxy Outpost** combined with a Traefik `Middleware` intercepts requests at the ingress layer and enforces authentication before the request reaches the application. The application itself never needs to know about Authentik.

To use Authentik as a forward auth provider, configure a Proxy Provider and Outpost in the Authentik UI, then create a Traefik `Middleware` resource pointing to the outpost:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forward-auth
  namespace: authentik
spec:
  forwardAuth:
    address: http://authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
      - X-authentik-name
      - X-authentik-uid
      - X-authentik-jwt
      - X-authentik-meta-jwks
      - X-authentik-meta-outpost
      - X-authentik-meta-provider
      - X-authentik-meta-app
      - X-authentik-meta-version
```

Reference this middleware in your other ingresses to protect them with Authentik authentication.

---

## Upgrading

```bash
helm repo update
helm upgrade authentik authentik/authentik \
  --namespace authentik \
  --values values.yaml
```

> Authentik runs database migrations on startup. Review the release notes before upgrading — breaking changes do appear between minor versions. Pin your chart version in production and upgrade deliberately.

---

## Resource Tuning

The resource limits in this document are reasonable starting points. Tune them to actual usage after the deployment has been running for a day or two:

```bash
kubectl top pods -n authentik
```

Set `requests` to the observed idle usage and `limits` high enough to handle auth traffic bursts without OOM kills.