# Bollingnet Kubernetes Cluster

A 6-node highly-available Kubernetes cluster running on the `10.0.4.0/24` network. The cluster is built and managed by Ansible, with kubeadm handling cluster bootstrapping, kube-vip providing control-plane high availability and `LoadBalancer` service IP assignment, and Flannel providing pod networking.

This document covers both the architecture of the deployed cluster and how to use the Ansible playbooks in this repository to stand it up, extend it, and operate it.

---

## Node Inventory

### Control Plane Nodes

| Hostname | FQDN | IP Address | Role |
|----------|------|------------|------|
| bn-kube-01 | bn-kube-01.int.bollingnet.net | 10.0.4.204 | Bootstrap control plane |
| bn-kube-02 | bn-kube-02.int.bollingnet.net | 10.0.4.205 | Control plane |
| bn-kube-03 | bn-kube-03.int.bollingnet.net | 10.0.4.206 | Control plane |

### Worker Nodes

| Hostname | FQDN | IP Address | Role |
|----------|------|------------|------|
| bn-kube-04 | bn-kube-04.int.bollingnet.net | 10.0.4.207 | Worker |
| bn-kube-05 | bn-kube-05.int.bollingnet.net | 10.0.4.208 | Worker |
| bn-kube-06 | bn-kube-06.int.bollingnet.net | 10.0.4.209 | Worker |

---

## Network Addressing

| Purpose | Address |
|---------|---------|
| Control plane VIP (kube-vip) | 10.0.4.10 |
| API server | https://10.0.4.10:6443 |
| Pod subnet (Flannel) | 10.244.0.0/16 |
| Service subnet (ClusterIPs) | 10.96.0.0/12 |
| LoadBalancer IP pool (kube-vip) | 10.0.4.210–10.0.4.254 |

---

## Components

| Component | Version | Purpose |
|-----------|---------|---------|
| Kubernetes | v1.35 | Container orchestration |
| kubeadm | v1.35 | Cluster bootstrapping |
| kubelet | v1.35 | Node agent |
| kubectl | v1.35 | CLI |
| containerd | System package | Container runtime |
| kube-vip | v1.1.2 | Control plane VIP + LoadBalancer IPs |
| kube-vip cloud provider | latest | LoadBalancer IP assignment |
| Flannel | latest | Pod networking (CNI) |
| kube-proxy | v1.35 | Service networking (iptables) |

---

## High Availability

### Control Plane

kube-vip runs as a static pod on each control plane node and uses ARP-based leader election to manage the control plane VIP (`10.0.4.10`). The current leader holds the VIP on its `eno1` interface and advertises it via ARP. If the leader node goes down, another control plane node acquires the VIP within 1–2 seconds.

The VIP is what `kubectl` and all worker nodes use to reach the API server — no single node IP is ever used for cluster communication.

### etcd

etcd runs as a static pod on each control plane node in a 3-member cluster. A quorum of 2 nodes is required. The cluster can tolerate the loss of 1 control plane node and continue operating normally.

---

## Ansible Automation

The cluster is fully managed by Ansible. The playbook and roles live under `ansible/` in this repository.

### Prerequisites

- All target nodes are defined in `inventory.yaml`
- The `kubernetes.core` Ansible collection is installed on your control machine:
  ```bash
  ansible-galaxy collection install -r requirements.yaml
  ```

### Inventory Groups

| Group | Purpose |
|-------|---------|
| `kubernetes_cluster` | All Kubernetes nodes (control-plane + workers) |
| `control_plane` | All control-plane nodes |
| `additional_control_plane` | Control-plane nodes that join after bootstrap (excludes the bootstrap node) |
| `workers` | Worker nodes |

### Playbook Tags

`ansible/playbooks/kubernetes-cluster.yaml` orchestrates the full cluster lifecycle using tagged phases. You can run a specific phase by passing `--tags <tag>`.

| Tag | Phase |
|-----|-------|
| `node_prep` | Install and configure prerequisites on all nodes |
| `bootstrap_control_plane` | Initialize the first control-plane node and deploy kube-vip |
| `join_control_plane` | Join additional control-plane nodes |
| `join_workers` | Join worker nodes |
| `kube_vip` | Deploy kube-vip on all control-plane nodes |

### Roles

#### `kubernetes_common`
Runs on every node before cluster setup. Handles:
- Kernel modules (`overlay`, `br_netfilter`)
- sysctl settings for bridge networking and IP forwarding
- Swap disabled permanently
- containerd installed and configured with systemd cgroups
- kubeadm, kubelet, and kubectl installed from the official Kubernetes APT repository and held at the configured version
- kubelet configured with the correct node IP

#### `kubernetes_control_plane`
Handles both bootstrap and join, depending on whether the node is the bootstrap node.

**Bootstrap tasks:**
- Renders and applies the kubeadm init config
- Runs `kubeadm init --upload-certs`
- Waits for the API server to be ready
- Deploys kube-proxy
- Grants `kubernetes-admin` cluster-admin RBAC
- Uploads all kubeadm config phases and bootstrap tokens
- Sets up anonymous RBAC for `cluster-info` (required for node joins)
- Deploys Flannel CNI
- Deploys kube-vip cloud provider
- Configures the kube-vip LoadBalancer IP pool
- Waits for Flannel pods to be ready

**Join tasks:**
- Copies join facts (token, CA hash, certificate key) from the bootstrap node
- Renders and executes the kubeadm join script

#### `kube_vip`
Deploys kube-vip as a static pod on control plane nodes. Generates the manifest using the kube-vip image itself via `ctr run`, configured for:
- ARP-based VIP management
- Leader election
- Control plane load balancing
- Service load balancing (`svc_enable`)

#### `kubernetes_worker`
Joins worker nodes to the cluster by copying join facts from the bootstrap node and executing `kubeadm join`.

### Configuration Variables

All variables are defined in `ansible/group_vars/kubernetes_cluster/vars.yaml`. Review and update them before running the playbook against a new environment.

| Variable | Default | Description |
|----------|---------|-------------|
| `kubernetes_version_minor` | `v1.35` | Minor version of Kubernetes to install. Controls the APT repository used for kubeadm, kubelet, and kubectl. |
| `cluster_name` | `bollingnet` | Name of the cluster. Used in kubeadm configuration. |
| `kube_vip_address` | `10.0.4.10` | Virtual IP address for the control plane. Must be a free IP on the same subnet as the control-plane nodes and outside your DHCP range. |
| `kube_vip_version` | `v1.1.2` | Version of the kube-vip image to deploy. |
| `kube_vip_lb_range` | `10.0.4.210-10.0.4.254` | IP range kube-vip uses to assign external IPs to `LoadBalancer` services. Must be a free range on the same subnet as your nodes and outside your DHCP range. |
| `kube_vip_interface` | Auto-detected | Network interface kube-vip binds to. Defaults to the interface of the default IPv4 route. Override with `kube_vip_interface_override`. |
| `pod_subnet` | `10.244.0.0/16` | CIDR used for pod IPs. Must not overlap with your node network or service subnet. The default is required by Flannel and should not be changed unless you switch CNI. |
| `service_subnet` | `10.96.0.0/12` | CIDR used for Kubernetes service ClusterIPs. Must not overlap with your node network or pod subnet. |
| `kube_node_ip` | Auto-detected | IP address advertised by kubelet for this node. Defaults to the default IPv4 address. Override with `kube_node_ip_override`. |
| `kubeadm_bootstrap_node` | `bn-kube-01.int.bollingnet.net` | FQDN of the node that runs `kubeadm init`. See the known issue below — this must also be passed on the command line with `-e`. |

### Known Issue: `kubeadm_bootstrap_node` Variable

The `kubeadm_bootstrap_node` variable must be passed on the command line with `-e` when running the playbook. If it is not, Ansible will fail to resolve it early in the play execution before it can be read from `group_vars`. Always include the following flag in your commands:

```bash
-e kubeadm_bootstrap_node=<bootstrap-node-fqdn>
```

---

## Standing Up a New Cluster

Run each phase in order from the `ansible/` directory.

### 1. Prepare all nodes

Installs and configures containerd, kubeadm, kubelet, and kubectl on every node in the cluster.

```bash
ansible-playbook -e kubeadm_bootstrap_node=<bootstrap-node-fqdn> \
  playbooks/kubernetes-cluster.yaml \
  --tags node_prep
```

### 2. Initialize the first control-plane node

Runs `kubeadm init`, deploys Flannel CNI, and deploys kube-vip on the bootstrap node.

```bash
ansible-playbook -e kubeadm_bootstrap_node=<bootstrap-node-fqdn> \
  playbooks/kubernetes-cluster.yaml \
  --tags bootstrap_control_plane
```

### 3. Join additional control-plane nodes

Joins the nodes in the `additional_control_plane` inventory group to the cluster and deploys kube-vip on each.

```bash
ansible-playbook -e kubeadm_bootstrap_node=<bootstrap-node-fqdn> \
  playbooks/kubernetes-cluster.yaml \
  --tags join_control_plane
```

### 4. Join worker nodes

Joins the nodes in the `workers` inventory group to the cluster.

```bash
ansible-playbook -e kubeadm_bootstrap_node=<bootstrap-node-fqdn> \
  playbooks/kubernetes-cluster.yaml \
  --tags join_workers
```

At the end of this step, the playbook will print instructions for copying the kubeconfig file to your local machine.

---

## Adding Additional Control-Plane Nodes

Add the new node(s) to the `kubernetes_cluster`, `control_plane`, and `additional_control_plane` groups in `inventory.yaml`, then run:

```bash
ansible-playbook -e kubeadm_bootstrap_node=<bootstrap-node-fqdn> \
  playbooks/kubernetes-cluster.yaml \
  --tags join_control_plane \
  --limit <new-node-fqdn>
```

---

## Adding Additional Worker Nodes

Add the new node(s) to the `kubernetes_cluster` and `workers` groups in `inventory.yaml`, then run node prep followed by the worker join:

```bash
ansible-playbook -e kubeadm_bootstrap_node=<bootstrap-node-fqdn> \
  playbooks/kubernetes-cluster.yaml \
  --tags node_prep \
  --limit <new-node-fqdn>

ansible-playbook -e kubeadm_bootstrap_node=<bootstrap-node-fqdn> \
  playbooks/kubernetes-cluster.yaml \
  --tags join_workers \
  --limit <new-node-fqdn>
```

---

## Accessing the Cluster

The kubeconfig file is located on the bootstrap node at `/etc/kubernetes/admin.conf`. Copy it to your local machine:

```bash
scp root@bn-kube-01.int.bollingnet.net:/etc/kubernetes/admin.conf ~/.kube/config
```

Verify access:

```bash
kubectl get nodes
```

---

## LoadBalancer Services

The kube-vip cloud provider watches for `LoadBalancer` type services and assigns IPs from the pool defined in the `kubevip` ConfigMap in `kube-system`. kube-vip then advertises those IPs via ARP on the control plane nodes.

### IP Pool Configuration

```bash
kubectl get configmap kubevip -n kube-system -o yaml
```

To update the pool:

```bash
kubectl edit configmap kubevip -n kube-system
```

Change `range-global` to the desired range. New services will draw from the updated range; existing services keep their assigned IPs.

### Exposing an Application

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 80
```

---

## Metrics Server

### Purpose

metrics-server collects CPU and memory usage from all nodes and pods and exposes them through the Kubernetes Metrics API. It is required for:

- `kubectl top nodes` and `kubectl top pods`
- k9s resource utilization display
- Horizontal Pod Autoscaler (HPA)

### Deployment

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### Configuration Required

The default metrics-server deployment will fail with TLS errors on a kubeadm cluster without additional configuration. Two issues must be resolved:

#### 1. IP SAN Error

By default metrics-server connects to kubelets by IP address, but kubelet serving certificates don't include IP SANs. Fix by adding `--kubelet-preferred-address-types=InternalDNS,ExternalDNS,Hostname` to the metrics-server deployment args so it connects by hostname instead:

```bash
kubectl edit deployment metrics-server -n kube-system
```

```yaml
args:
  - --cert-dir=/tmp
  - --secure-port=10250
  - --kubelet-preferred-address-types=InternalDNS,ExternalDNS,Hostname
  - --kubelet-use-node-status-port
  - --metric-resolution=15s
```

> **Note:** This requires CoreDNS to be running and able to resolve node hostnames. CoreDNS is deployed automatically by the Ansible bootstrap playbook.

#### 2. Unknown Certificate Authority Error

Kubelet serving certificates are self-signed by default and not signed by the cluster CA, causing metrics-server to reject them with "certificate signed by unknown authority". Fix by enabling kubelet server TLS bootstrapping on every node:

```bash
# Run on ALL nodes (control plane and workers)
echo "serverTLSBootstrap: true" >> /var/lib/kubelet/config.yaml
systemctl restart kubelet
```

Then approve the pending CSRs from the bootstrap node:

```bash
kubectl get csr --no-headers | awk '{print $1}' | xargs kubectl certificate approve
```

This is now configured automatically in the kubeadm init config (`serverTLSBootstrap: true` in `KubeletConfiguration`) so new clusters will not require this manual step. On new clusters the bootstrap playbook also automatically approves the CSRs.

### Verifying Metrics Are Working

```bash
kubectl top nodes
kubectl top pods -A
```

---

## Useful Commands

```bash
# Node status
kubectl get nodes -o wide

# All pods across all namespaces
kubectl get pods -A

# kube-vip status
kubectl get pods -n kube-system | grep kube-vip

# Flannel status
kubectl get pods -n kube-flannel

# LoadBalancer services
kubectl get services -A | grep LoadBalancer

# kube-vip IP pool
kubectl get configmap kubevip -n kube-system -o yaml
```
