#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# cloud-init does not export HOME into the user-data shell, so pin it to
# root's home. kubectl otherwise cannot discover the kubeconfig.
export HOME="${HOME:-/root}"

# Everything the script prints is captured here so cloud-init / SSH debugging is easy
LOG_FILE="/var/log/kubernetes-master.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Node 0 is always the control plane
sudo hostnamectl set-hostname kubernetes-master

echo "=== Kubernetes Master bootstrap started on $(hostname) at $(date) ==="

# ------------------------------------------------------------------
# 1. System preparation required by kubeadm
# ------------------------------------------------------------------
# Kubernetes refuses to run if swap is enabled, so turn it off for this
# boot and remove it from /etc/fstab so it stays off after a reboot.
echo "--- Step 1/9: System preparation (swap off, kernel modules, sysctls) ---"
sudo swapoff -a
sudo sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

# Load the kernel modules Kubernetes networking needs:
#   overlay      -> used by containerd for container file-systems
#   br_netfilter -> lets iptables see traffic passing through bridges (needed for cluster networking)

sudo tee /etc/modules-load.d/k8s.conf > /dev/null <<'EOF'
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Networking sysctls required for pods to reach services and the outside world
sudo tee /etc/sysctl.d/k8s.conf > /dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
echo "OK: Swap off, kernel modules and sysctls configured"

# ------------------------------------------------------------------
# 2. Update packages and install the container runtime + tools
# ------------------------------------------------------------------
echo "--- Step 2/9: Installing base packages and AWS CLI ---"
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg containerd

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then 
    AWS_ARCH="x86_64"
elif [ "$ARCH" = "aarch64" ]; then 
    AWS_ARCH="aarch64"
fi

curl "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "awscliv2.zip"
sudo apt-get install -y unzip
unzip awscliv2.zip
sudo ./aws/install --update
rm -rf aws awscliv2.zip
echo "OK: Base packages and AWS CLI installed"

# ------------------------------------------------------------------
# 3. Configure containerd to use the systemd cgroup driver
# ------------------------------------------------------------------
# Kubernetes (kubelet) is managed by systemd, so the container runtime
# MUST use systemd cgroups too or the two will fight over control of the
# cgroups and pods will crash. Enable it explicitly in the CRI plugin.
echo "--- Step 3/9: Configuring containerd (systemd cgroup driver) ---"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
echo "OK: containerd running with SystemdCgroup=true"

# ------------------------------------------------------------------
# 4. Resolve the LATEST stable Kubernetes version automatically
# ------------------------------------------------------------------
# dl.k8s.io is the official "latest stable release" endpoint.
# Example value: v1.36.3  ->  K8S_MINOR = v1.36
echo "--- Step 4/9: Resolving Kubernetes version and adding apt repo ---"
K8S_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
K8S_MINOR=${K8S_VERSION%.*}
echo "Latest stable Kubernetes version detected: ${K8S_VERSION}"

# Add the official Kubernetes apt repository for that minor version
# (pkgs.k8s.io only publishes per-minor channels, e.g. core:/stable:/v1.36)
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y

# apt-cache madison shows every version available in the repo; the first
# row is the newest. Its exact package version (e.g. 1.36.3-1.1) is then
# pinned across kubeadm, kubelet and kubectl so all three always match.
K8S_PKG_VERSION=$(apt-cache madison kubeadm | awk 'NR==1 {print $3}')
echo "Installing Kubernetes components at version: ${K8S_PKG_VERSION}"

sudo apt-get install -y "kubeadm=${K8S_PKG_VERSION}" "kubelet=${K8S_PKG_VERSION}" "kubectl=${K8S_PKG_VERSION}"

# Prevent accidental upgrades from mixing kubelet/kubeadm/kubectl versions
sudo apt-mark hold kubeadm kubelet kubectl
echo "OK: Kubernetes binaries installed and held at version ${K8S_PKG_VERSION}"

# ------------------------------------------------------------------
# 5. Initialise the control plane (master)
# ------------------------------------------------------------------
# 10.244.0.0/16 is the default Pod CIDR that the Calico manifest expects.
# The CRI socket is passed explicitly so kubeadm talks to containerd.
echo "--- Step 5/9: Initializing control plane (kubeadm init) ---"
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket=unix:///run/containerd/containerd.sock
echo "OK: Control plane initialized"

# ------------------------------------------------------------------
# 6. Configure kubectl for root and ubuntu
# ------------------------------------------------------------------
echo "--- Step 6/9: Configuring kubectl for root and ubuntu ---"
sudo mkdir -p /root/.kube
sudo cp -i /etc/kubernetes/admin.conf /root/.kube/config
sudo chown "$(id -u):$(id -g)" /root/.kube/config
export KUBECONFIG=/root/.kube/config

sudo mkdir -p /home/ubuntu/.kube
sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config
echo "export KUBECONFIG=/home/ubuntu/.kube/config" | sudo tee /etc/profile.d/kubectl.sh > /dev/null
echo "OK: kubectl configured"

# ------------------------------------------------------------------
# 7. Deploy the Calico Container Network Interface (CNI)
# ------------------------------------------------------------------
# Every pod needs a CNI provider; Calico gives each pod a routable IP and
# enforces network policy. Manifest versions are pinned to known-good tags.
echo "--- Step 7/9: Deploying Calico CNI ---"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml
echo "OK: Calico CNI deployed"

# ------------------------------------------------------------------
# 8. Deploy the NGINX Ingress Controller
# ------------------------------------------------------------------
# Lets external traffic reach services through Ingress resources.
# The "baremetal" manifest is used because we are not on a cloud LB provider.
echo "--- Step 8/9: Deploying NGINX Ingress Controller ---"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/baremetal/deploy.yaml
echo "OK: NGINX Ingress Controller deployed"

# ------------------------------------------------------------------
# 9. Publish the worker join command to SSM Parameter Store
# ------------------------------------------------------------------
# Workers are separate EC2 instances started at the same time, so the
# easiest way to share the secret token/cert-hash is via SSM. Each worker
# polls this parameter and runs whatever command appears here.
# Terraform replaces "__SSM_PARAMETER_NAME__" with the real path.
echo "--- Step 9/9: Publishing join command to SSM ---"
PARAMETER_NAME="${SSM_PARAMETER_NAME:-__SSM_PARAMETER_NAME__}"

# Purge any stale value left over from a previous cluster cycle. After a
# destroy/re-apply the master gets a NEW private IP; if this parameter still
# held the old join command, workers would read a dead IP and fail. Deleting
# first guarantees workers only ever see a fresh command.
aws ssm delete-parameter --name "${PARAMETER_NAME}" 2>/dev/null || true

for attempt in $(seq 1 10); do
  if JOIN_COMMAND=$(sudo kubeadm token create --print-join-command 2>/dev/null); then
    aws ssm put-parameter --name "${PARAMETER_NAME}" --type String --value "${JOIN_COMMAND}" --overwrite > /dev/null
    echo "Join command published to SSM parameter: ${PARAMETER_NAME}"
    break
  fi
  echo "kubeadm token not ready yet (attempt ${attempt}/10), retrying in 10s..."
  sleep 10
done

echo "=== Kubernetes Master bootstrap completed at $(date) ==="
