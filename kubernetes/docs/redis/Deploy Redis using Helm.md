# Deploy Redis using Helm

Standalone Redis deployment using the Bitnami Helm chart with optional persistent storage. Suitable as a shared Redis instance for multiple applications in the same cluster.

---

## Prerequisites

- Kubernetes cluster with Helm installed
- `redis` namespace created
- A persistent storage class available (optional but recommended — see [Persistence](#persistence))

---

## 1. Create Namespace

```bash
kubectl create namespace redis
```

---

## 2. Create Auth Secret

Generate a strong random password and store it as a Kubernetes secret. Run as a single line to avoid shell line-continuation issues:

```bash
kubectl create secret generic redis-auth --namespace redis --from-literal=redis-password=$(openssl rand -base64 64)
```

> **Important:** Retrieve and store the password somewhere safe before continuing — you'll need it when wiring Redis into consuming applications.
>
> ```bash
> kubectl get secret redis-auth -n redis -o jsonpath='{.data.redis-password}' | base64 -d
> ```

---

## 3. Add Bitnami Helm Repo

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

---

## 4. Create `values.yaml`

```yaml
architecture: standalone

auth:
  enabled: true
  existingSecret: redis-auth
  existingSecretPasswordKey: redis-password

master:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 1Gi

  persistence:
    enabled: true
    storageClass: longhorn   # adjust to your storage class — see Persistence section
    size: 2Gi

  configuration: |
    maxmemory 896mb
    maxmemory-policy allkeys-lru

replica:
  replicaCount: 0
```

### Key configuration notes

| Setting | Value | Reason |
|---|---|---|
| `architecture` | `standalone` | Single replica; no Sentinel overhead needed |
| `maxmemory` | `896mb` | Slightly under the 1Gi limit to prevent OOM kills |
| `maxmemory-policy` | `allkeys-lru` | Evicts least-recently-used keys cluster-wide; frequently-accessed keys (e.g. session data) naturally stay hot |
| `replicaCount` | `0` | Disables replica pods in standalone mode |

> **Resource limits** are a reasonable starting point but should be tuned to actual usage after deployment. Monitor with `kubectl top pods -n redis` after a day or two of traffic.

---

## Persistence

Redis data is ephemeral by default — a pod restart will clear all keys. For most cache-only workloads this is acceptable, but if Redis is used as a task queue or session store, persistence is recommended.

### With a persistent storage class (recommended)

Set your cluster's storage class in `values.yaml`:

```yaml
master:
  persistence:
    enabled: true
    storageClass: longhorn   # replace with your storage class (e.g. local-path, ceph-block, standard)
    size: 2Gi
```

To list available storage classes in your cluster:

```bash
kubectl get storageclass
```

### Without persistence

If you don't have a storage class available, or Redis is used purely as a cache where data loss is tolerable:

```yaml
master:
  persistence:
    enabled: false
```

> Without persistence, all Redis data is lost on pod restart. Applications using Redis for sessions (e.g. Authentik) will log all users out; applications using it as a cache (e.g. WordPress) will experience a cold-start with no functional impact.

---

## 5. Deploy

```bash
helm install redis bitnami/redis \
  --namespace redis \
  --values values.yaml
```

Pin to a specific chart version in production:

```bash
# Check available versions
helm search repo bitnami/redis --versions

# Install pinned version
helm install redis bitnami/redis \
  --namespace redis \
  --values values.yaml \
  --version <chart-version>
```

---

## 6. Verify

```bash
# Check pod is running
kubectl get pods -n redis

# Confirm PVC is bound (if persistence is enabled)
kubectl get pvc -n redis

# Connectivity test
kubectl run redis-test --rm -it --restart=Never \
  --namespace redis \
  --image redis:alpine \
  -- redis-cli -h redis-master.redis.svc.cluster.local \
     -a $(kubectl get secret redis-auth -n redis -o jsonpath='{.data.redis-password}' | base64 -d) \
     ping
```

Expected output: `PONG`

---

## 7. In-Cluster Connection Details

| Property | Value |
|---|---|
| Host | `redis-master.redis.svc.cluster.local` |
| Port | `6379` |
| Auth secret | `redis-auth` (namespace: `redis`) |
| Auth secret key | `redis-password` |

---

## 8. Sharing Redis Across Applications

A single Redis instance can serve multiple applications using separate database numbers, which namespace each application's keys without additional overhead.

| Database | Purpose |
|---|---|
| `0` | Default — first application (e.g. Authentik) |
| `1` | Second application (e.g. WordPress object cache) |
| `2+` | Additional applications as needed |

### Cross-namespace secret access

Kubernetes `secretKeyRef` cannot reference secrets across namespaces. Each consuming application needs a copy of the Redis password in its own namespace:

```bash
REDIS_PASS=$(kubectl get secret redis-auth -n redis -o jsonpath='{.data.redis-password}' | base64 -d)

kubectl create secret generic <app>-redis-auth \
  --namespace <app-namespace> \
  --from-literal=redis-password=$REDIS_PASS
```

Then reference it in the application's deployment or Helm values via `secretKeyRef`:

```yaml
env:
  - name: REDIS_PASSWORD   # adjust to the application's expected env var name
    valueFrom:
      secretKeyRef:
        name: <app>-redis-auth
        key: redis-password
```

> When rotating the Redis password, remember to update the secret in every namespace that holds a copy.

---

## 9. Upgrading

```bash
helm repo update
helm upgrade redis bitnami/redis \
  --namespace redis \
  --values values.yaml
```

> Redis upgrades are generally safe for a cache/broker workload — data loss is recoverable. Applications may experience brief session invalidation or cache cold-starts during the restart.