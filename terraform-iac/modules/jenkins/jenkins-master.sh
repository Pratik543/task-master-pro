#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Set the hostname to jenkins-master
sudo hostnamectl set-hostname jenkins-master

echo "=== Setting up Jenkins Master on $(hostname) ==="

# Update package lists and install prerequisites (retry once if the first update is flaky)
sudo apt-get update -y
sudo apt-get install -y openjdk-21-jdk wget curl ca-certificates gnupg

# Add the Jenkins repository key and source
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | sudo tee \
  /usr/share/keyrings/jenkins-keyring.asc > /dev/null

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null

# Install Jenkins
sudo apt-get update -y
sudo apt-get install -y jenkins

# Add Docker's official GPG key:
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add the current user to the docker group so they can run docker without sudo
sudo usermod -aG docker ubuntu
sudo usermod -aG docker jenkins


