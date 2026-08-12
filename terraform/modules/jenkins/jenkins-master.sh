#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

echo "==> Setting hostname to jenkins-master"
sudo hostnamectl set-hostname jenkins-master

echo "=== Setting up Jenkins Master on $(hostname) ==="

echo "==> Updating package lists"
sudo apt-get update -y

echo "==> Installing prerequisites (openjdk-21-jdk, wget, curl, ca-certificates, gnupg)"
sudo apt-get install -y openjdk-21-jdk wget curl ca-certificates gnupg

echo "==> Downloading and installing Jenkins repository key"
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | sudo tee \
  /usr/share/keyrings/jenkins-keyring.asc > /dev/null

echo "==> Adding Jenkins apt repository"
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null

echo "==> Updating package lists to load Jenkins repository"
sudo apt-get update -y

echo "==> Installing Jenkins"
sudo apt-get install -y jenkins

echo "==> Installing ca-certificates and curl"
sudo apt install ca-certificates curl

echo "==> Creating /etc/apt/keyrings directory"
sudo install -m 0755 -d /etc/apt/keyrings

echo "==> Downloading Docker GPG key"
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc

echo "==> Setting permissions on Docker GPG key"
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "==> Adding Docker apt repository"
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

echo "==> Updating package lists to load Docker repository"
sudo apt-get update -y

echo "==> Installing Docker (docker-ce, containerd.io, buildx, compose)"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Adding ubuntu user to docker group"
sudo usermod -aG docker ubuntu

echo "==> Adding jenkins user to docker group"
sudo usermod -aG docker jenkins

echo "==> Installing Trivy (vulnerability scanner)"
sudo apt-get install -y wget gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y trivy
trivy --version

echo "==> Downloading kubectl CLI"
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
echo "Latest stable kubectl version detected: ${KUBECTL_VERSION}"

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  KUBECTL_ARCH="amd64"
else
  KUBECTL_ARCH="arm64"
fi

curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl
kubectl version --client

echo "=== Jenkins Master setup completed ==="
