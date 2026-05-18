# Deploying Longhorn

This guide walks through deploying Longhorn as a distributed block storage system on Kubernetes, including node preparation, preflight validation, Helm installation, and exposing the dashboard over HTTPS.

## Prerequisites

- A running Kubernetes cluster with worker nodes running a Debian-based OS
- `kubectl` configured to talk to your cluster
- Helm installed (`brew install helm` or see [helm.sh](https://helm.sh))
- Ansible installed and configured with an inventory that includes a `workers` group
- cert-manager deployed and a `ClusterIssuer` configured (see `cert-manager/` docs)
- Traefik deployed as the ingress controller (see `traefik/` docs)

---

## Step 1 – Prepare Worker Nodes (Ansible)

Longhorn requires several kernel modules and system services to be present on every worker node before installation.

Run the prerequisites playbook:

```bash
ansible-playbook playbooks/install-longhorn-prerequsites.yaml
```

The playbook does the following on every host in the `workers` group:

| Task | Detail |
|---|---|
| Install `nfs-common` | Required for Longhorn's NFS-backed volumes |
| Load `nfs` kernel module | Activates immediately and persisted via `/etc/modules-load.d/longhorn.conf` |
| Load `dm_crypt` kernel module | Activates immediately and persisted via `/etc/modules-load.d/longhorn.conf` |
| Configure multipathd blacklist | Prevents multipathd from interfering with Longhorn block devices; iSCSI targets remain unaffected |
| Enable `iscsid.socket` | Starts iscsid on-demand (Longhorn's preferred activation mode) |

> **Note on multipathd:** The playbook configures `/etc/multipath.conf` to blacklist all `sd*` devices while preserving iSCSI multipath targets. If you do not use multipath at all, you can instead disable/mask `multipathd` and remove that task from the playbook.

---

## Step 2 – Run Preflight Checks

`longhornctl` is Longhorn's official CLI for validating that nodes meet all requirements before installation.

Download the binary for your architecture from the [Longhorn releases page](https://github.com/longhorn/cli/releases) and place it in your PATH.

Check all nodes:

```bash
longhornctl check preflight
```

Review the output and resolve any reported issues before proceeding. Common items flagged include missing kernel modules, disabled `iscsid`, and multipathd conflicts — all of which the Ansible playbook in Step 1 addresses.

---

## Step 3 – Install Longhorn with Helm

Add the Longhorn Helm repository:

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

Create the namespace:

```bash
kubectl create namespace longhorn-system
```

Install Longhorn:

```bash
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version <LONGHORN-VERSION>
```

Replace `<LONGHORN-VERSION>` with the desired chart version (e.g. `1.7.2`). Check available versions with `helm search repo longhorn/longhorn --versions`.

To upgrade an existing installation after changing values:

```bash
helm upgrade longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version <LONGHORN-VERSION>
```

Verify pods come up healthy:

```bash
kubectl -n longhorn-system get pods
```

---

## Step 4 – Create a TLS Certificate

Apply the certificate resource so cert-manager provisions a TLS secret for the dashboard:

```yaml
# longhorn-dashboard-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: longhorn-dashboard
  namespace: longhorn-system
spec:
  secretName: tls-longhorn-dashboard
  commonName: longhorn.<YOUR-DOMAIN>
  dnsNames:
    - longhorn.<YOUR-DOMAIN>
  issuerRef:
    name: <YOUR-CLUSTER-ISSUER-NAME>  # Must match the name of your ClusterIssuer
    kind: ClusterIssuer
```

Replace `longhorn.<YOUR-DOMAIN>` with the hostname you want to use for the dashboard, and `<YOUR-CLUSTER-ISSUER-NAME>` with the name of the `ClusterIssuer` defined in your cert-manager setup.

```bash
kubectl apply -f longhorn-dashboard-certificate.yaml
```

Verify the certificate is issued:

```bash
kubectl -n longhorn-system get certificate longhorn-dashboard
```

---

## Step 5 – Expose the Dashboard via Traefik

Apply the `IngressRoute` to route external traffic to the Longhorn frontend:

```yaml
# longhorn-ingressroute.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: longhorn-dashboard
  namespace: longhorn-system
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`longhorn.<YOUR-DOMAIN>`)
      kind: Rule
      services:
        - name: longhorn-frontend
          port: 80
  tls:
    secretName: tls-longhorn-dashboard  # Must match spec.secretName in longhorn-dashboard-certificate.yaml
```

```bash
kubectl apply -f longhorn-ingressroute.yaml
```

Once deployed, the dashboard is available at:

```
https://longhorn.<YOUR-DOMAIN>
```

---

## Production Considerations

| Topic | Homelab | Production |
|---|---|---|
| Dashboard exposure | Expose freely on internal network | Restrict with authentication middleware (e.g. Traefik BasicAuth or forward auth) |
| Default replica count | 3 (default) | Keep at 3 or higher; tune per storage class |
| Storage over-provisioning | Default is acceptable | Set `storageOverProvisioningPercentage` based on actual workload |
| Node tagging | Not required | Tag dedicated storage nodes and use node selectors to isolate Longhorn workloads |
| Backup target | Optional | Configure an S3-compatible or NFS backup target for disaster recovery |
