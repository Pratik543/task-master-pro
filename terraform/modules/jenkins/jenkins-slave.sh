#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

echo "==> Setting hostname to jenkins-slave"
sudo hostnamectl set-hostname jenkins-slave

echo "=== Setting up Jenkins Slave Node on $(hostname) ==="

echo "==> Updating package lists"
sudo apt-get update -y

echo "==> Installing prerequisites (openjdk-21-jdk, curl, ca-certificates, gnupg)"
sudo apt-get install -y openjdk-21-jdk curl ca-certificates gnupg

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

echo "=== Jenkins Slave setup completed ==="
