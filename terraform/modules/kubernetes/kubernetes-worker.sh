#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/kubernetes-worker.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Terraform replaces "__NODE_HOSTNAME__" with kubernetes-worker-01, -02, ...
# NODE_HOSTNAME env var is a fallback for running the script standalone.
sudo hostnamectl set-hostname "${NODE_HOSTNAME:-__NODE_HOSTNAME__}"

echo "=== Kubernetes Worker bootstrap started on $(hostname) at $(date) ==="

# ------------------------------------------------------------------
# 1. System preparation required by kubeadm
# ------------------------------------------------------------------
echo "--- Step 1/5: System preparation (swap off, kernel modules, sysctls) ---"
sudo swapoff -a
sudo sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

sudo tee /etc/modules-load.d/k8s.conf > /dev/null <<'EOF'
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

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
echo "--- Step 2/5: Installing base packages and AWS CLI ---"
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
# 3. Configure containerd with the systemd cgroup driver
# ------------------------------------------------------------------
# Must match the kubelet cgroup driver used on the control plane.
echo "--- Step 3/5: Configuring containerd (systemd cgroup driver) ---"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
echo "OK: containerd running with SystemdCgroup=true"

# ------------------------------------------------------------------
# 4. Resolve the LATEST stable Kubernetes version automatically
# ------------------------------------------------------------------
echo "--- Step 4/5: Resolving Kubernetes version and adding apt repo ---"
K8S_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
K8S_MINOR=${K8S_VERSION%.*}
echo "Latest stable Kubernetes version detected: ${K8S_VERSION}"

sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y

K8S_PKG_VERSION=$(apt-cache madison kubeadm | awk 'NR==1 {print $3}')
echo "Installing Kubernetes components at version: ${K8S_PKG_VERSION}"

sudo apt-get install -y "kubeadm=${K8S_PKG_VERSION}" "kubelet=${K8S_PKG_VERSION}" "kubectl=${K8S_PKG_VERSION}"
sudo apt-mark hold kubeadm kubelet kubectl
echo "OK: Kubernetes binaries installed and held at version ${K8S_PKG_VERSION}"

# ------------------------------------------------------------------
# 5. Wait for the master to publish a REACHABLE join command, then join
# ------------------------------------------------------------------
# Workers are launched at the same time as the master, which needs a few
# minutes to boot and run `kubeadm init`. Instead of guessing, each worker
# polls SSM Parameter Store until the master has written the join command
# (a short-lived token + the CA cert hash for the API server).
# Terraform replaces "__SSM_PARAMETER_NAME__" with the real path.
#
# The join command embeds the master's private IP. After a destroy/re-apply
# the master gets a NEW IP, so SSM can briefly hold a STALE command pointing
# at the old, destroyed instance ("no route to host"). To survive that race
# we re-fetch the parameter every cycle and only join once the embedded API
# server actually answers /healthz.
echo "--- Step 5/5: Waiting for join command and joining the cluster ---"
PARAMETER_NAME="${SSM_PARAMETER_NAME:-__SSM_PARAMETER_NAME__}"

JOIN_COMMAND=""
echo "Waiting for a reachable join command at SSM parameter: ${PARAMETER_NAME}"
for attempt in $(seq 1 90); do
  # Re-fetch every cycle so a refreshed (new-master) command is picked up.
  JOIN_COMMAND=$(aws ssm get-parameter --name "${PARAMETER_NAME}" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)

  if [ -n "${JOIN_COMMAND}" ]; then
    # The join command looks like: kubeadm join <ip>:6443 --token ... --discovery-token-ca-cert-hash sha256:...
    MASTER_API=$(echo "${JOIN_COMMAND}" | awk '{print $3}')

    # Only proceed once the embedded API server is actually healthy. A stale
    # command points at a dead IP -> curl fails -> we keep polling instead of
    # failing with "no route to host".
    if [ -n "${MASTER_API}" ] && curl -ksS --connect-timeout 10 --max-time 10 \
        "https://${MASTER_API}/healthz" 2>/dev/null | grep -q "ok"; then
      echo "Join command received on attempt ${attempt}/90; API server healthy at ${MASTER_API}."
      break
    fi
    echo "Join command present but API server ${MASTER_API} not healthy yet (attempt ${attempt}/90), retrying in 10s..."
  else
    echo "Join command not available yet (attempt ${attempt}/90), retrying in 10s..."
  fi

  JOIN_COMMAND=""
  sleep 10
done

if [ -z "${JOIN_COMMAND}" ]; then
  echo "ERROR: Timed out waiting for a reachable join command at SSM parameter ${PARAMETER_NAME}"
  exit 1
fi

# The join command is a plain string like:
#   kubeadm join <master-private-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
# Running it registers this node with the control plane. Even after a healthy
# /healthz the API may briefly reject joins, so retry a few times, re-fetching
# the command each round in case the token was refreshed.
echo "Joining the Kubernetes cluster..."
JOINED=0
for jatt in $(seq 1 5); do
  if sudo ${JOIN_COMMAND}; then
    JOINED=1
    echo "OK: Kubernetes worker joined the main cluster."
    break
  fi
  echo "kubeadm join failed (attempt ${jatt}/5); API may still be initializing. Retrying in 15s..."
  sleep 15
  JOIN_COMMAND=$(aws ssm get-parameter --name "${PARAMETER_NAME}" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)
done

if [ "${JOINED}" -ne 1 ]; then
  echo "ERROR: Failed to join the Kubernetes cluster after multiple attempts. Inspect: sudo journalctl -u kubelet -f"
  exit 1
fi

echo "=== Kubernetes Worker bootstrap completed at $(date) ==="
