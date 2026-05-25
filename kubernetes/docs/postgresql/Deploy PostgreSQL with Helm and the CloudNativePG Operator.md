# Deploy a 3-node PostgreSQL Cluster with Helm and the CloudNativePG Operator

This guide walks through deploying a highly-available 3-node PostgreSQL cluster on Kubernetes using:

- CloudNativePG
- Longhorn (optional)
- Kubernetes internal DNS/service discovery
- SOPS-managed secrets (optional)

This example assumes:

- A working Kubernetes cluster
- Longhorn already installed
- `kubectl` configured
- A dedicated namespace named `postgresql`

---

## 1. Create the Database Namespace

```bash
kubectl create namespace database
```

Verify:

```bash
kubectl get ns
```

---

## 2. Install the CloudNativePG Operator

Add the Helm repository:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
```

Install the operator:

```bash
helm upgrade --install cloudnative-pg \
  cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace
```

Verify:

```bash
kubectl get pods -n cnpg-system
```

Expected:

```text
cloudnative-pg-xxxxxxxxxx-xxxxx   Running
```

---

## 3. Create a Single-Replica Longhorn Storage Class (Optional)

**The following section is only applicable if you're using [Longhorn](https://longhorn.io) storage in your environment and are concerned about disk usage**

By default, Longhorn creates 3 storage replicas per volume.

For replicated PostgreSQL clusters, this is often unnecessary because PostgreSQL itself already replicates data across nodes.

Without optimization:

```text
3 PostgreSQL nodes × 10Gi PVC × 3 Longhorn replicas = 90Gi consumed
```

Using a single-replica storage class reduces this to:

```text
3 PostgreSQL nodes × 10Gi PVC × 1 replica = 30Gi consumed
```

Create `longhorn-single-replica.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-single-replica

provisioner: driver.longhorn.io

allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate

parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  fsType: "ext4"
```

Apply:

```bash
kubectl apply -f longhorn-single-replica.yaml
```

Verify:

```bash
kubectl get storageclass
```

Expected:

```text
longhorn-single-replica
```

---

## 4. Create a PostgreSQL Cluster Manifest

Create `postgresql-cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster

metadata:
  name: postgresql-cluster
  namespace: postgresql

spec:
  instances: 3

  storage:
    storageClass: longhorn-single-replica
    size: 10Gi

  monitoring:
    enablePodMonitor: true
```

Placeholder values you may wish to customize:

| Field | Example | Description |
|---|---|---|
| `name` | `postgresql-cluster` | PostgreSQL cluster name |
| `namespace` | `postgresql` | Kubernetes namespace |
| `storageClass` | `longhorn-single-replica` | Storage backend |
| `size` | `10Gi` | PVC size |
| `instances` | `3` | Number of PostgreSQL instances |

Apply:

```bash
kubectl apply -f postgresql-cluster.yaml
```

---

## 5. Verify Cluster Health

Watch pods initialize:

```bash
kubectl get pods -n postgresql -w
```

Expected:

```text
postgresql-cluster-1   Running
postgresql-cluster-2   Running
postgresql-cluster-3   Running
```

Check cluster status:

```bash
kubectl get cluster -n postgresql
```

Example:

```text
NAME                 AGE   INSTANCES   READY   STATUS
postgresql-cluster   5m    3           3       Cluster in healthy state
```

---

## 6. Inspect Generated Services

CNPG automatically creates Kubernetes Services for PostgreSQL access.

List services:

```bash
kubectl get svc -n postgresql
```

Expected:

```text
postgresql-cluster-rw
postgresql-cluster-ro
postgresql-cluster-r
```

### Service Purpose

| Service | Purpose |
|---|---|
| `postgresql-cluster-rw` | Primary read/write endpoint |
| `postgresql-cluster-ro` | Read-only replicas |
| `postgresql-cluster-r` | Generic read endpoint |

Applications should normally connect to:

```text
postgresql-cluster-rw.database.svc.cluster.local
```

---

## 7. Install the CNPG kubectl Plugin (Optional but Recommended)

MacOS:

```bash
brew install kubectl-cnpg
```

Verify:

```bash
kubectl cnpg version
```

Useful commands:

```bash
kubectl cnpg status postgresql-cluster -n postgresql
```

```bash
kubectl cnpg report cluster postgresql-cluster -n postgresql
```

---

## 8. Create an Application Database/User

You can manage database credentials in one of two ways:

1. Plaintext Kubernetes Secrets (simple)
2. SOPS-encrypted Secrets (recommended)

---

### Option 1: Create a Plaintext Kubernetes Secret

### Create a Kubernetes Secret

Example:

```yaml
apiVersion: v1
kind: Secret

metadata:
  name: app-db-user
  namespace: postgresql

type: kubernetes.io/basic-auth

stringData:
  username: <APP_USERNAME>
  password: <APP_PASSWORD>
```

Replace:

- `<APP_USERNAME>`
- `<APP_PASSWORD>`

Apply:

```bash
kubectl apply -f app-secret.yaml
```

> WARNING:
>
> This approach stores credentials in plaintext within Git if committed directly to a repository.
>
> For production or GitOps workflows, consider using the SOPS-based workflow below.

---

### Option 2: Manage Secrets with SOPS (Recommended)

Instead of storing plaintext passwords in Git, you can use SOPS with `age` encryption to securely manage Kubernetes secrets.

This is especially useful if you plan to use:
- GitOps
- ArgoCD
- GitHub Actions
- Infrastructure-as-Code workflows

#### Install SOPS and age

MacOS:

```bash
brew install sops age
```

#### Generate an age Key

Create a local encryption key:

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

Example output:

```text
Public key: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Save the public key value.

#### Create a `.sops.yaml` Configuration File

At the root of your Git repository:

```yaml
creation_rules:
  - path_regex: .*secret.*\.ya?ml
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Replace:

- `age1xxxxxxxx...` with your actual public key

#### Encrypt the Secret

Encrypt the file in-place:

```bash
sops --encrypt --in-place app-secret.yaml
```

#### Deploy the Secret

Apply the secret directly to Kubernetes without writing decrypted contents to disk:

```bash
sops -d app-secret.yaml | kubectl apply -f -
```

---

### Update the PostgreSQL Cluster

Add managed roles:

```yaml
spec:
  managed:
    roles:
      - name: <APP_USERNAME>
        ensure: present
        login: true
        passwordSecret:
          name: app-db-user
```

Apply:

```bash
kubectl apply -f postgresql-cluster.yaml
```

---

### Create the Application Database

Example:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database

metadata:
  name: app-database
  namespace: postgresql

spec:
  name: <APP_DATABASE_NAME>
  owner: <APP_USERNAME>

  cluster:
    name: postgresql-cluster
```

Replace:

- `<APP_DATABASE_NAME>`
- `<APP_USERNAME>`

Apply:

```bash
kubectl apply -f app-database.yaml
```

## 9. Application Connection Example

Applications connect using Kubernetes DNS:

```text
Host: postgresql-cluster-rw.database.svc.cluster.local
Port: 5432
Database: <APP_DATABASE_NAME>
Username: <APP_USERNAME>
Password: <APP_PASSWORD>
```

Example connection string:

```text
postgresql://<APP_USERNAME>:<APP_PASSWORD>@postgresql-cluster-rw.database.svc.cluster.local:5432/<APP_DATABASE_NAME>
```

---

## Useful Commands

View cluster status:

```bash
kubectl cnpg status postgresql-cluster -n postgresql
```

View pods:

```bash
kubectl get pods -n postgresql
```

View PVCs:

```bash
kubectl get pvc -n postgresql
```

View PostgreSQL services:

```bash
kubectl get svc -n postgresql
```

Check which pod is primary:

```bash
kubectl cnpg status postgresql-cluster -n postgresql
```

Connect to PostgreSQL:

```bash
kubectl exec -it -n postgresql postgresql-cluster-1 -- psql
```