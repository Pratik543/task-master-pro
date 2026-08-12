# Kubernetes Cluster Setup — Kubeadm Userdata (Auto-Latest Version)

This document explains **what** every file in this module does, **what it is for**, and **why** it is built the way it is. It accompanies three runtime files:

| File | Role |
| --- | --- |
| `kubernetes-master.sh` | Runs on **node 0** (control plane). Installs Kubernetes, runs `kubeadm init`, installs Calico + NGINX Ingress, publishes the join command. |
| `kubernetes-worker.sh` | Runs on **every other node** (workers). Installs Kubernetes and joins the cluster using the command published by the master. |
| `main.tf` / `variables.tf` / `outputs.tf` | Terraform wiring: applies the correct script per node, gives nodes the IAM permission to share the join command over SSM Parameter Store. |

---

## 1. Big picture: how the whole thing works

1. Terraform creates `instance_count` EC2 instances in the same subnet (default 3).
2. `count.index == 0` → that instance gets `kubernetes-master.sh` as **user_data**.
3. Every other instance gets `kubernetes-worker.sh`.
4. The master boots, installs everything, runs `kubeadm init`, and finally writes the `kubeadm join ...` command into **SSM Parameter Store**.
5. Workers boot at the same time. They install Kubernetes first, then **poll SSM** until the join command exists, then run it to join the cluster.

### Hostnames follow the node count

Each node's OS hostname (and its EC2 `Name` tag) is derived from `var.instance_count`:

| Node index | Hostname |
| --- | --- |
| 0 | `kubernetes-master` |
| 1 | `kubernetes-worker-01` |
| 2 | `kubernetes-worker-02` |
| … | `kubernetes-worker-NN` (zero-padded) |

Terraform computes these in a `locals` block and injects them into the scripts via a `__NODE_HOSTNAME__` placeholder. Hostnames are set with `hostnamectl set-hostname` **before** `kubeadm init`/`join`, which matters because kubelet registers each node in the cluster under its hostname — do it too late and the node shows up under a wrong name.

```
              +---------------------+       aws ssm put-parameter
              |  Master (node 0)    | ------------------------------+
              |  kubeadm init       |                               |
              +---------------------+                               v
                                                          /kubernetes/join-command
                                                          (SSM Parameter Store)
              +---------------------+                               ^
              |  Worker (node 1)    | ------------------------------+
              |  kubeadm join ...   |      aws ssm get-parameter (poll)
              +---------------------+
```

The SSM hand-off exists because all nodes start at **the same time**. The master cannot tell workers "I'm ready" with a file inside its own filesystem — workers have no shared disk. SSM Parameter Store acts as the shared mailbox.

---

## 2. Why the Kubernetes version is detected automatically

Your original recipe pinned `kubeadm=1.28.1-1.1`. That means:

- every re-run installs an old version,
- you must manually edit the script whenever a new Kubernetes minor is released.

The script instead resolves the version **at boot time** in two steps:

```bash
K8S_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)   # e.g. v1.36.3
K8S_MINOR=${K8S_VERSION%.*}                                      # e.g. v1.36
```

- `https://dl.k8s.io/release/stable.txt` is Kubernetes' **official** "latest stable release" endpoint. It always returns the newest stable version.
- `${K8S_VERSION%.*}` strips everything after the **second** dot, giving `v1.36`. This matters because `pkgs.k8s.io` does **not** publish a version-less "latest" repository (a request to `core:/stable/deb/` returns `403`). It only publishes per-minor channels like `core:/stable:/v1.36/deb/`. So we must know the minor first.

The exact **package** version (e.g. `1.36.3-1.1`, with its build suffix) is then taken from the repository itself:

```bash
K8S_PKG_VERSION=$(apt-cache madison kubeadm | awk 'NR==1 {print $3}')
sudo apt-get install -y "kubeadm=${K8S_PKG_VERSION}" "kubelet=${K8S_PKG_VERSION}" "kubectl=${K8S_PKG_VERSION}"
```

- `apt-cache madison` lists every version the repo offers; the first row is the newest.
- Pinning **all three** binaries to the same exact version prevents the classic "kubelet 1.36 / kubeadm 1.35 mismatch" failure. `apt-mark hold kubeadm kubelet kubectl` then stops a future `apt upgrade` from breaking the trio.

---

## 3. Why containerd instead of Docker

Docker used to ship a built-in Kubernetes runtime ("dockershim"). Kubernetes **removed dockershim in v1.24**. On any modern version (v1.36 today) Docker alone cannot run pods — you would need `cri-dockerd` as an adapter, and the cluster would be a layer of indirection away from the supported path.

**containerd** is the **official CRI (Container Runtime Interface) runtime** for Kubernetes. Every kubeadm setup, every managed cluster (EKS, GKE, AKS), and every cloud provider's Kubernetes image uses it. Choosing containerd means:
- zero adapters,
- guaranteed compatibility with the latest Kubernetes,
- less memory than a full Docker daemon.

### The one critical containerd setting

```bash
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
```

`SystemdCgroup = true` makes containerd place containers into **systemd cgroups** — the same cgroup driver the kubelet uses. If they differ, containerd and kubelet argue over cgroup ownership and pods crash-loop. **This is the most common "why are my pods stuck in ContainerCreating" fix** in kubeadm clusters.

---

## 4. The mandatory preflight steps (usually forgotten in quick recipes)

Your original recipe skipped these. `kubeadm init` **fails preflight checks** without them:

```bash
sudo swapoff -a
sudo sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab
```

- kubeadm explicitly rejects nodes with swap on; kubelet requires swap off. Editing `/etc/fstab` (commenting, not deleting) keeps swap off after a reboot.

```bash
sudo modprobe overlay
sudo modprobe br_netfilter
# persisted via /etc/modules-load.d/k8s.conf
```

- `overlay` — the filesystem containerd uses for container layers.
- `br_netfilter` — allows iptables to inspect traffic crossing Linux bridges, which is how pod-to-pod / pod-to-service traffic is filtered.

```bash
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
```

- Written to `/etc/sysctl.d/k8s.conf` so they survive reboots. Without these, pods cannot reach services, and kube-proxy / Calico routes will not work.

---

## 5. Master script walk-through (`kubernetes-master.sh`)

1. **Logging** — `exec > >(tee -a /var/log/kubernetes-master.log) 2>&1` captures every line. In EC2, user_data runs as root at boot; if something fails you can `cat /var/log/kubernetes-master.log` instead of fighting the cloud-init console output. `set -euo pipefail` aborts on the first error, treats unset variables as bugs, and catches failing pipeline stages.

2. **System prep** — described in §4.

3. **Base packages** — `apt-transport-https` (TLS for the apt repo), `ca-certificates`, `curl`, `gnupg` (GPG key handling), `containerd`, and **`awscli`** (needed to write to SSM; Ubuntu 24.04 AMIs do not ship the CLI by default).

4. **Dynamic version** — described in §2.

5. **`kubeadm init`**:

   ```bash
   sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket=unix:///run/containerd/containerd.sock
   ```

   - `--pod-network-cidr=10.244.0.0/16` — the IP range assigned to pods. **This exact range is what Calico expects by default**, so the two must agree.
   - `--cri-socket=...` — tells kubeadm to talk to containerd directly (explicit is safer than letting it guess).

6. **kubectl config** — `admin.conf` is copied to `$HOME/.kube/config` and chowned, so the root user can run `kubectl` without flags. The `-i` flag prevents overwrite prompts on re-runs.

7. **Calico (CNI)** — pods cannot talk to each other until a CNI plugin exists. Calico assigns each pod a routable IP and implements `NetworkPolicy`. The version is **pinned** (`v3.32.1`) because a future tag could change the manifest format or require a newer Kubernetes. `kubectl apply` here runs against the freshly configured kubeconfig.

8. **NGINX Ingress Controller** — the bridge between the internet and your services. Instead of giving every service a public LoadBalancer, one NGINX controller reads `Ingress` resources and routes traffic by hostname/path. The **`baremetal`** manifest is used because we are not behind an AWS Load Balancer (a bare VM + `NodePort` setup).

9. **Publish join command to SSM**:

   ```bash
   JOIN_COMMAND=$(sudo kubeadm token create --print-join-command)
   aws ssm put-parameter --name "${PARAMETER_NAME}" --type String --value "${JOIN_COMMAND}" --overwrite
   ```

   `kubeadm token create --print-join-command` outputs a ready-to-run line containing:
   - the master's **private IP:6443** (workers reach it inside the VPC),
   - a short-lived **bootstrap token** (the "secret"),
   - the **CA cert hash** so workers can trust the API server (prevents MITM).

   The retry loop exists because the token API may not be ready in the seconds right after init. `--overwrite` makes re-runs idempotent.

> The path itself is the string `__SSM_PARAMETER_NAME__` — a **placeholder** that Terraform swaps for the real value (see §7).

---

## 6. Worker script walk-through (`kubernetes-worker.sh`)

Sections 1–4 are **identical** to the master — a worker must have the exact same kernel settings, container runtime, and Kubernetes version, or `kubeadm join` rejects it.

The difference is section 5:

```bash
for attempt in $(seq 1 90); do
  if JOIN_COMMAND=$(aws ssm get-parameter --name "${PARAMETER_NAME}" --with-decryption --query Parameter.Value --output text 2>/dev/null); then
    break
  fi
  sleep 10
done
```

- Workers start **before** the master has finished `kubeadm init`, so the parameter does not exist yet. Instead of failing, they poll every 10 seconds for up to **15 minutes** (90 × 10s), which comfortably covers the master's boot + install + init time.
- `--with-decryption` is harmless for a plain `String` and future-proofs the script.

Then:

```bash
sudo ${JOIN_COMMAND}
```

- The variable holds `kubeadm join <ip>:6443 --token ... --discovery-token-ca-cert-hash sha256:...`.
- It is **unquoted on purpose**: the shell word-splits it into the command plus its flags (exactly what `--print-join-command` intends).
- It runs as root because `kubeadm` needs to write `/var/lib/kubelet` and `/etc/kubernetes`.

If the 15-minute timeout is hit, the script logs a clear error and exits non-zero (visible in cloud-init status and `/var/log/kubernetes-worker.log`).

---

## 7. Terraform wiring (`main.tf`)

### 7.1 Choosing the right script per node

```hcl
locals {
  node_hostnames = [
    for i in range(var.instance_count) :
    i == 0 ? "kubernetes-master" : format("kubernetes-worker-%02d", i)
  ]
}

user_data = replace(
  replace(
    file("${path.module}/${count.index == 0 ? "kubernetes-master.sh" : "kubernetes-worker.sh"}"),
    "__SSM_PARAMETER_NAME__",
    var.ssm_parameter_name,
  ),
  "__NODE_HOSTNAME__",
  local.node_hostnames[count.index],
)
```

- **`count.index == 0`** → node 0 is the master; all others are workers.
- **`locals.node_hostnames`** builds one hostname per node from `instance_count`: node 0 → `kubernetes-master`, node N → `kubernetes-worker-NN` (zero-padded).
- **`replace(..., "__SSM_PARAMETER_NAME__", ...)` and the nested `replace(..., "__NODE_HOSTNAME__", ...)`** inject the real parameter path and the per-node hostname into the script.
  - We use plain string replacement rather than `templatefile()` because `templatefile` would treat **every** `${...}` in the bash script (e.g. `${K8S_VERSION}`) as a Terraform interpolation and fail. `replace()` only touches the exact placeholders.
  - The scripts also fall back to sensible defaults at runtime (`"/kubernetes/join-command"` for SSM, `NODE_HOSTNAME` env var for the hostname), so they remain runnable standalone outside Terraform.
- The instance `Name` tag is set to the same hostname (`Name = local.node_hostnames[count.index]`), keeping the AWS console consistent with the OS hostname.

### 7.2 IAM so the scripts can use SSM

The AWS CLI on an instance needs credentials. These come from an **IAM instance profile** attached to the EC2 instance — no static keys in the script.

- **`aws_iam_role.k8s_node`** — trust policy allowing the `ec2.amazonaws.com` service to assume it.
- **`aws_iam_role_policy.k8s_node`** — grants only `ssm:GetParameter` and `ssm:PutParameter`, scoped to the **single** parameter ARN:

  ```
  arn:aws:ssm:<region>:<account>:parameter<ssm_parameter_name>
  ```

  Least privilege: the nodes can touch the join-command parameter and nothing else.
- **`aws_iam_instance_profile.k8s_node`** — binds the role so it can be attached to instances via `iam_instance_profile`.
- **`data "aws_region"` / `data "aws_caller_identity"`** — resolve the current region/account at plan time so the ARN is always correct, no hardcoding.

### 7.3 Variables & outputs

- `variables.tf` — `ssm_parameter_name` (default `/kubernetes/join-command`) is the single knob controlling the shared-mailbox path. Change it once and both the scripts and the IAM policy follow.
- `outputs.tf` — added `kubernetes_join_ssm_parameter` so you can see (and query) the parameter that holds the join command.

---

## 8. What the existing security group already covers

No security group changes were needed. The default SG in `modules/network` already allows:

- **6443** — Kubernetes API server (workers → master),
- **30000–32768** — NodePort range (Ingress controller + `kubectl get nodes` from the internet),
- **22, 80, 443, 3000–10000, 25, 465** — SSH, HTTP(S), app ports, mail,
- **all egress**.

Since all nodes share this SG with full egress, kubelet (10250), Calico (BGP/overlay), and the API server can all communicate.

---

## 9. How to verify it worked

On the master (node 0):

```bash
# Cluster nodes: should show 1 Ready master + N Ready workers after ~2-4 min
kubectl get nodes

# All namespaces, all pods running (calico, ingress-nginx, kube-system)
kubectl get pods -A

# Read the join command from SSM if you want to add a node by hand
aws ssm get-parameter --name /kubernetes/join-command --query Parameter.Value --output text

# Node readiness
kubectl get nodes -o wide
```

On any node, check bootstrap logs:

```bash
sudo tail -f /var/log/cloud-init-output.log        # cloud-init console
cat /var/log/kubernetes-master.log                  # or kubernetes-worker.log
```

---

## 10. Troubleshooting cheat-sheet

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `kubeadm init` / `join` preflight fails on swap | Swap enabled | script does `swapoff -a` + edits fstab; reboot test: `swapon --show` |
| Pods stuck `ContainerCreating` | containerd `SystemdCgroup` mismatch | `grep SystemdCgroup /etc/containerd/config.toml` → must be `true`, restart containerd |
| Worker timeout at SSM | Parameter name mismatch | Compare `terraform output kubernetes_join_ssm_parameter` with the `__SSM_PARAMETER_NAME__` replaced value; check IAM profile attached |
| `kubectl get nodes` shows master only | Workers failed to join | `cat /var/log/kubernetes-worker.log` on a worker; re-check SG 6443 + token expiry |
| API server unreachable from workers | SG blocks 6443 / wrong subnet | SG already opens 6443 from `0.0.0.0/0`; confirm same VPC/subnet |
| Version drift after `apt upgrade` | packages not held | script runs `apt-mark hold kubeadm kubelet kubectl` |
| `aws: command not found` | AWS CLI missing | script installs `awscli` (Ubuntu package) |
