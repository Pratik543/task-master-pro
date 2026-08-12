# Kubernetes First Login Checklist

What to verify on each node right after your first SSH login, using the bootstrap scripts in this module (`kubernetes-master.sh` / `kubernetes-worker.sh`).

## 0. Get the node addresses

Run from your local machine inside `terraform/`:

```sh
terraform output kubernetes_node_public_ips
terraform output kubernetes_node_elastic_ips
terraform output kubernetes_node_ssh_commands
```

SSH as the `ubuntu` user with your key pair (name from `terraform.tfvars` → `key_name`):

```sh
ssh -i <key_name>.pem ubuntu@<elastic-ip>
```

> Use the **Elastic IP**, not the ephemeral public IP. If you can't connect, see [SSH Troubleshooting](#7-ssh-troubleshooting).

---

## 1. Was the bootstrap actually done?

```bash
sudo cloud-init status --long        # should say: done (no errors)
sudo tail -100 /var/log/cloud-init-output.log
cat /var/log/kubernetes-master.log    # or /var/log/kubernetes-worker.log
```

The scripts use `set -euo pipefail`, so the **first unhandled error aborts the run** — the log shows exactly which `--- Step N/N ---` marker was the last one printed. Every step prints an `OK:` line on success:

| Step | Marker |
| --- | --- |
| 1 | System preparation (swap off, kernel modules, sysctls) |
| 2 | Installing base packages and AWS CLI |
| 3 | Configuring containerd (systemd cgroup driver) |
| 4 | Resolving Kubernetes version and adding apt repo |
| 5 (master) | Initializing control plane (kubeadm init) |
| 6 (master) | Configuring kubectl for root and ubuntu |
| 7 (master) | Deploying Calico CNI |
| 8 (master) | Deploying NGINX Ingress Controller |
| 9 (master) | Publishing join command to SSM |
| 5 (worker) | Waiting for join command and joining the cluster |

Expected final lines:

```text
OK: Kubernetes binaries installed and held at version 1.3x.y-z
...
=== Kubernetes Master bootstrap completed at ... ===
```

or for a worker:

```text
Join command received on attempt N/90.
OK: Joined the Kubernetes cluster
=== Kubernetes Worker bootstrap completed at ... ===
```

---

## 2. System state kubeadm requires

```bash
swapon --show                    # must print NOTHING (swap is off)
free -h                          # RAM — c7i-flex.large = 4 GB
df -h /                          # root volume — 20 GB default
lsmod | grep -E 'overlay|br_netfilter'   # both modules loaded
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward   # all = 1
```

---

## 3. Container runtime

```bash
systemctl status containerd --no-pager        # active (running)
systemctl is-enabled containerd                # enabled
grep SystemdCgroup /etc/containerd/config.toml # must be: SystemdCgroup = true
ctr version
```

---

## 4. Kubernetes binaries (versions must match)

```bash
kubeadm version
kubelet --version
kubectl version --client
apt-mark showhold                                # kubeadm, kubelet, kubectl held
```

All three must report the **same** version (they are pinned together by the bootstrap script).

---

## 5. On the master — cluster health

Since Step 6 of the bootstrap configures kubectl for **both** the `root` and `ubuntu` users, you can run kubectl directly as `ubuntu` (the SSH user). `sudo kubectl` also works for root.

```bash
kubectl get nodes -o wide          # master Ready + N workers Ready (no sudo needed as ubuntu)
kubectl get nodes -o wide -w       # watch until all Ready
kubectl get pods -A                # calico + ingress-nginx in Running
kubectl get svc -n ingress-nginx   # NodePort LoadBalancer IP
kubectl get cs                     # control plane components Healthy
```

Health criteria:

- `STATUS` for every node is `Ready` (2–4 min after bootstrap).
- `kube-system` pods (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `coredns`) are `Running`/`Completed`.
- `calico` pods in `kube-system` are `Running` (CNI is up).
- `ingress-nginx-controller` pod is `Running`.

If a node is `NotReady`, inspect on that node:

```bash
sudo journalctl -u kubelet -f --no-pager
sudo crictl ps                         # container runtime still healthy?
```

---

## 6. On a worker — did it join?

Workers don't ship a kubeconfig, so check from the master:

```bash
kubectl get nodes -o wide
```

Or inspect the worker itself:

```bash
cat /var/log/kubernetes-worker.log
sudo systemctl status kubelet --no-pager
```

Read the join command published to SSM (any machine with the instance role, or from the master):

```bash
aws ssm get-parameter --name /kubernetes/join-command --query Parameter.Value --output text
```

---

## 7. SSH troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Permission denied (publickey)` | wrong key, wrong user, or key name mismatch | `ssh -i <key_name>.pem ubuntu@<elastic-ip>`; confirm key pair name in `terraform.tfvars` matches the AWS key pair |
| `UNPROTECTED PRIVATE KEY FILE` (Windows) | `.pem` ACLs too open | `icacls admin.pem /inheritance:r /grant:r "$($env:USERNAME):(R)"` |
| Connection timeout | wrong IP / SG blocks 22 / instance not running | use the **Elastic IP**; SG opens 22 from `0.0.0.0/0` |
| `Host key verification failed` | IP reused from a previous instance | `ssh-keygen -R <ip>` then retry |

---

## 8. Common bootstrap failure symptoms → root cause

| Symptom | Root cause | Fix |
| --- | --- | --- |
| Script stops at a step marker | first unhandled error; cloud-init env quirks | read `/var/log/kubernetes-master.log`; e.g. `HOME` unset → script now pins `HOME=/root` |
| `kubectl` talks to `localhost:8080` | kubeconfig not discovered | script exports `KUBECONFIG=/root/.kube/config` |
| Pods stuck `ContainerCreating` | containerd `SystemdCgroup` mismatch | `grep SystemdCgroup /etc/containerd/config.toml` must be `true`, restart containerd |
| Worker timeout at SSM | parameter name mismatch / IAM profile missing | compare `terraform output kubernetes_join_ssm_parameter`; confirm IAM profile attached |
| `kubectl get nodes` shows master only | workers failed to join | `cat /var/log/kubernetes-worker.log` on a worker; check SG 6443 + token expiry |
| `kubeadm init` preflight fails on swap | swap enabled | script runs `swapoff -a` + comments `/etc/fstab`; verify `swapon --show` is empty |
| Version drift after `apt upgrade` | packages not held | script runs `apt-mark hold kubeadm kubelet kubectl` |
| `aws: command not found` | AWS CLI missing | script installs AWS CLI v2 (master) / `awscli` (worker) |

---

## 9. Stale join-command race (worker: `no route to host`)

When the Kubernetes module is **destroyed and re-created** (e.g. `terraform destroy -target='module.kubernetes[0]'` then `apply`), the master gets a **new private IP**. The old join command stays in SSM until the new master boots and overwrites it. Workers launched in that window read the **stale** command and fail:

```text
error execution phase preflight: couldn't validate the identity of the API Server:
... Get "https://<old-master-ip>:6443/...": dial tcp <old-master-ip>:6443: connect: no route to host
```

`no route to host` to an IP **inside the same subnet** means that IP no longer exists (ARP failure) — the master was re-created.

**Diagnose:**
```bash
# What does SSM currently point at?
aws ssm get-parameter --name /kubernetes/join-command --query Parameter.Value --output text

# What is the live master IP?
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=kubernetes-master" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].[PrivateIpAddress,PublicIpAddress]" --output table
```

**Fix (join the workers with the current command):**
```bash
JOIN=$(aws ssm get-parameter --name /kubernetes/join-command --query Parameter.Value --output text)
sudo $JOIN
```
Then verify from the master: `kubectl get nodes`.

> Note: the stale value only persists if the new master never re-published. The bootstrap writes SSM with `--overwrite` during Step 9, so after the master finishes, the value is current again. Retrying the join is enough; tearing down the workers is not required.

---

## 10. kubectl config for `root` vs. `ubuntu` (and cert expiry)

Step 6 of the master bootstrap copies `admin.conf` to **both**:

| Location | Used by |
| --- | --- |
| `/root/.kube/config` | `sudo kubectl` and the bootstrap's own `kubectl apply` (Steps 7/8) |
| `/home/ubuntu/.kube/config` | plain `kubectl` when SSH'd in as `ubuntu` |
| `/etc/profile.d/kubectl.sh` | exports `KUBECONFIG=/home/ubuntu/.kube/config` on login for `ubuntu` |

Both are safe to keep — no conflict. If you drop the root one, `sudo kubectl` falls back to `localhost:8080` (sudo strips `KUBECONFIG`); use `sudo -i kubectl` in that case.

**Is the copy one-time?** Yes, the *copying* is one-time (run during bootstrap), but the config is **not valid forever**:
- The `admin.conf` client certificate expires **1 year** after `kubeadm init`.
- `kubeadm upgrade`/`kubeadm certs renew` rotate the certs; your previously copied kubeconfigs become **stale** until re-copied.

**Refresh later (only after cert rotation/expiry — not needed now):**
```bash
sudo cp /etc/kubernetes/admin.conf /root/.kube/config
sudo chown root:root /root/.kube/config
sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config
```

**Check cert expiry on the master:**
```bash
openssl x509 -in /etc/kubernetes/admin.conf -noout -enddate
```
