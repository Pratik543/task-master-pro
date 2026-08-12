# Task Master Pro — End-to-End CI/CD & Infrastructure Runbook

This guide walks through the **complete lifecycle** of the project's DevOps
setup:

- [Task Master Pro — End-to-End CI/CD \& Infrastructure Runbook](#task-master-pro--end-to-end-cicd--infrastructure-runbook)
  - [1. How it fits together](#1-how-it-fits-together)
  - [2. Prerequisites](#2-prerequisites)
  - [3. Create `terraform.tfvars`](#3-create-terraformtfvars)
  - [4. Phase 1 — Provision AWS infrastructure for Jenkins](#4-phase-1--provision-aws-infrastructure-for-jenkins)
    - [What the bootstrap already installed for you](#what-the-bootstrap-already-installed-for-you)
  - [5. Phase 2 — Jenkins server setup \& configuration](#5-phase-2--jenkins-server-setup--configuration)
    - [5.1 First login](#51-first-login)
    - [5.2 Plugins to install](#52-plugins-to-install)
    - [5.3 Global tools](#53-global-tools)
    - [5.4 Credentials](#54-credentials)
    - [5.5 SonarQube server in system config](#55-sonarqube-server-in-system-config)
    - [5.6 (Optional) Connect the slave as a Jenkins agent](#56-optional-connect-the-slave-as-a-jenkins-agent)
  - [6. Phase 3 — SonarQube \& Nexus on the Jenkins slave](#6-phase-3--sonarqube--nexus-on-the-jenkins-slave)
    - [6.1 Recommended — Docker Compose](#61-recommended--docker-compose)
    - [6.2 Alternative — `docker run`](#62-alternative--docker-run)
    - [6.3 First login — SonarQube](#63-first-login--sonarqube)
    - [6.4 First login — Nexus](#64-first-login--nexus)
  - [7. Phase 4 — Wire Jenkins to SonarQube \& Nexus and push the artifact](#7-phase-4--wire-jenkins-to-sonarqube--nexus-and-push-the-artifact)
    - [7.1 Point Maven at Nexus](#71-point-maven-at-nexus)
    - [7.2 Option A — Push via the Jenkins pipeline (recommended)](#72-option-a--push-via-the-jenkins-pipeline-recommended)
    - [7.3 Option B — Manual `mvn deploy`](#73-option-b--manual-mvn-deploy)
  - [8. Phase 5 — Provision the Kubernetes cluster when you are ready](#8-phase-5--provision-the-kubernetes-cluster-when-you-are-ready)
  - [9. Phase 6 — RBAC for the pipeline and deploy the app](#9-phase-6--rbac-for-the-pipeline-and-deploy-the-app)
    - [9.1 Create the namespace and RBAC](#91-create-the-namespace-and-rbac)
    - [9.2 Verify and capture the token](#92-verify-and-capture-the-token)
    - [9.3 Point the `Jenkinsfile` at the cluster](#93-point-the-jenkinsfile-at-the-cluster)
    - [9.4 Deploy the app](#94-deploy-the-app)
  - [10. Teardown](#10-teardown)
  - [11. Reference](#11-reference)
    - [Security group ports](#security-group-ports)
    - [Service map](#service-map)
    - [Key files](#key-files)

---

## 1. How it fits together

```
Developer ── push ──► GitHub
                       │
                       ├─► GitHub Actions (deploy.yml)
                       │
                       └─► Jenkins (master)  ──► SonarQube (slave)  ──► Docker Hub
                                               └─► Nexus (slave)             │
                                                                             ▼
                                                                         Kubernetes
                                                                         (webapps ns)
```

| Component      | Where it runs                  | Purpose                                                  |
| -------------- | ------------------------------ | -------------------------------------------------------- |
| Jenkins master | EC2 `Jenkins-Master-Server`    | CI server, runs the `Jenkinsfile` pipeline               |
| Jenkins slave  | EC2 `Jenkins-Slave-Node`       | Hosts **SonarQube** (9000) + **Nexus** (8081) via Docker |
| SonarQube      | Docker on slave (`:9000`)      | Static code analysis                                     |
| Nexus 3        | Docker on slave (`:8081`)      | Maven artifact repository                                |
| Kubernetes     | EC2 cluster (master + workers) | Runs the deployed app                                    |

All AWS resources are created with **Terraform** (see [`terraform/`](./terraform)).
The bootstrap scripts pre-install most software, so you configure Jenkins from
the web UI, not the shell.

---

## 2. Prerequisites

1. **Terraform 1.x+** — <https://developer.hashicorp.com/terraform/downloads>
2. **AWS credentials** — configured via default profile or `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` with EC2, S3, and SSM permissions
3. **EC2 key pair** — created in `ap-south-1`; its name becomes `key_name`
4. **S3 state bucket** — the remote backend uses
   `task-master-pro-terraform-state`; create it if missing:

```sh
aws s3api create-bucket --bucket task-master-pro-terraform-state --region ap-south-1 --create-bucket-configuration LocationConstraint=ap-south-1
```

---

## 3. Create `terraform.tfvars`

Copy the example and fill in your values:

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

```hcl
key_name                    = "your-aws-generated-keypair"   # EC2 key pair name
instance_type               = "m7i-flex.large"               # 8 GB RAM — Jenkins + slave
kubernetes_instance_type    = "m7i-flex.large"               # used only in Phase 5
kubernetes_instance_count   = 3
vpc_cidr                    = "10.0.0.0/16"
subnet_cidr                 = "10.0.1.0/24"
availability_zone           = "ap-south-1a"
project_name                = "task-master"
enable_kubernetes           = false                          # keep false until Phase 5
```

> `terraform.tfvars` is git-ignored so secrets and personal values never get
> committed.

---

## 4. Phase 1 — Provision AWS infrastructure for Jenkins

The root config always provisions the **network** and **jenkins** modules.
The **kubernetes** module is skipped while `enable_kubernetes = false`.

```sh
# Inside terraform/
terraform init                       # downloads AWS provider + S3 backend
terraform validate                   # syntax check
terraform plan                       # review what will be created
terraform apply --auto-approve
```

**What gets created now**

- **network**: VPC (`10.0.0.0/16`), internet gateway, public subnet
  (`10.0.1.0/24`, `ap-south-1a`), default route `0.0.0.0/0 → IGW`, default SG
- **jenkins**:
  - `Jenkins-Master-Server` — user-data runs `jenkins-master.sh`
  - `Jenkins-Slave-Node` — user-data runs `jenkins-slave.sh`
  - one Elastic IP per instance

**Read the outputs:**

```sh
terraform output
terraform output jenkins_server_ssh_command
terraform output jenkins_slave_node_ssh_command
```

**SSH into the Jenkins server:**

> Wait a few minutes after `terraform apply` before SSHing in — the instances
> need time to boot and run their `user_data` bootstrap scripts (installs
> Jenkins, Docker, Trivy, kubectl, etc.). Logging in too early shows a plain
> box with nothing installed yet.

```sh
ssh -i <key_name>.pem ubuntu@<jenkins-server-elastic-ip>
```

### What the bootstrap already installed for you

`jenkins-master.sh` (on the master):

- OpenJDK 21
- Jenkins (from the official Debian repo, version 2026 keyring)
- Docker (`docker-ce`, buildx, compose plugin) — `ubuntu` and `jenkins` added
  to the `docker` group
- **Trivy** (container vulnerability scanner)
- **kubectl** (latest stable)

`jenkins-slave.sh` (on the slave):

- OpenJDK 21
- Docker (`docker-ce`, buildx, compose plugin)

Verify on each box (bootstrapping happens on first boot):

```sh
sudo tail -50 /var/log/cloud-init-output.log
java -version
docker --version
trivy --version          # master only
kubectl version --client # master only
```

---

## 5. Phase 2 — Jenkins server setup & configuration

### 5.1 First login

```sh
# From your local machine
echo "http://$(curl ifconfig.me):8080"   # or just http://<jenkins-elastic-ip>:8080

# From the Jenkins server
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `http://<jenkins-elastic-ip>:8080`, paste the admin password, install the
suggested plugins, and create the admin user.

### 5.2 Plugins to install

Manage Jenkins → **Plugins → Available plugins**:

- SonarQube Scanner
- Nexus Artifact Uploader
- Docker
- Docker Pipeline
- Docker Build Step
- Pipeline Stage View
- OWASP Dependency-Check
- Kubernetes
- Kubernetes CLI

### 5.3 Global tools

Manage Jenkins → **Tools**:

| Tool name       | Type              | Path / version                                                                                               |
| --------------- | ----------------- | ------------------------------------------------------------------------------------------------------------ |
| `jdk21`         | JDK install       | `readlink -f $(which java)` → `/usr/lib/jvm/java-21-openjdk-amd64/` — install manually and set **JAVA_HOME** |
| `maven3`        | Maven install     | Install automatically (e.g. 3.9.x)                                                                           |
| `sonar-scanner` | SonarQube Scanner | Install automatically                                                                                        |
| `dp-check`      | Dependency-Check  | Install automatically                                                                                        |
| `docker`        | Docker install    | `readlink -f $(which docker)` → `/usr/bin/`                                                                  |

> The `jdk21` and `docker` tools use paths, so those binaries must exist on
> whichever node runs the build (the Jenkins master by default, or the slave
> agent — see [§5.6](#56-optional-connect-the-slave-as-a-jenkins-agent)).

### 5.4 Credentials

Manage Jenkins → **Credentials** → global:

| Credential ID  | Type                | Value                                          |
| -------------- | ------------------- | ---------------------------------------------- |
| `sonar-token`  | Secret text         | Token generated in SonarQube (Phase 3)         |
| `docker-creds` | Username + password | Docker Hub account                             |
| `nexus-creds`  | Username + password | Nexus user (Phase 3)                           |
| `k8s-token`    | Secret text         | Kubernetes service-account token (**Phase 6**) |

### 5.5 SonarQube server in system config

Manage Jenkins → **System** → *SonarQube installations* → **Add SonarQube**:

```
Name:                 sonar-server
Server URL:           http://<jenkins-slave-elastic-ip>:9000
Server authentication token: sonar-token   # from credentials above
```

> The pipeline stage `withSonarQubeEnv('sonar-server')` looks up this exact
> name.

### 5.6 (Optional) Connect the slave as a Jenkins agent

The pipeline works on `agent any` (the master). If you want the slave to run
builds:

1. Slave must reach the master on `8080` and the master must reach the slave's
   agent port.
2. Manage Jenkins → **Nodes → New Node** → name it `slave` → permanent agent.
3. Set the remote root directory (e.g. `/home/ubuntu/jenkins`), labels, and the
   launch method with the slave's SSH credentials.
4. Keep it simple for this runbook — the master executes the pipeline fine.

---

## 6. Phase 3 — SonarQube & Nexus on the Jenkins slave

SonarQube and Nexus run as Docker containers on the **slave** node.

> Docker is already installed by `jenkins-slave.sh`. The recommended way is the
> compose file shipped in the repo. `docker run` equivalents are given too.

### 6.1 Recommended — Docker Compose

Copy the compose file from your local machine to the slave and start it:

```sh
# From your local machine
scp -i <key_name>.pem \
  terraform/modules/jenkins/jenkins-slave-for-nexus-sonar.yaml \
  ubuntu@<jenkins-slave-elastic-ip>:

# From the slave
sudo usermod -aG docker ubuntu && newgrp docker   # if not already a member
docker compose -f jenkins-slave-for-nexus-sonar.yaml up -d
```

`jenkins-slave-for-nexus-sonar.yaml` starts:

| Service     | Image              | Port        | Volumes                                                    |
| ----------- | ------------------ | ----------- | ---------------------------------------------------------- |
| `sonarqube` | `sonarqube:latest` | `9000:9000` | `sonarqube_data`, `sonarqube_logs`, `sonarqube_extensions` |
| `nexus`     | `sonatype/nexus3`  | `8081:8081` | `nexus-data`                                               |

Both use `restart: unless-stopped`.

### 6.2 Alternative — `docker run`

```sh
docker run -d --name sonarqube -p 9000:9000 \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_logs:/opt/sonarqube/logs \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  sonarqube:latest

docker run -d --name nexus -p 8081:8081 \
  -v nexus-data:/nexus-data \
  sonatype/nexus3
```

### 6.3 First login — SonarQube

```sh
echo "http://<jenkins-slave-elastic-ip>:9000"
```

Default login: `admin` / `admin`. Change it, then generate an **API token**
(User → My Account → Security): save it as the `sonar-token` Jenkins
credential.

### 6.4 First login — Nexus

```sh
# Initial admin password lives inside the nexus-data volume
sudo cat /var/lib/docker/volumes/jenkins-slave-for-nexus-sonar_nexus-data/_data/admin.password

echo "http://<jenkins-slave-elastic-ip>:8081"
```

Log in with `admin` + that password, set a new password, and create/edit a
Maven user (`nexus-creds`). Nexus ships with `maven-releases` and
`maven-snapshots` repositories out of the box — the pipeline uses
`maven-snapshots`.

---

## 7. Phase 4 — Wire Jenkins to SonarQube & Nexus and push the artifact

### 7.1 Point Maven at Nexus

Update the `<distributionManagement>` block in [`pom.xml`](./pom.xml) so the
artifact is uploaded to your Nexus:

```xml
<distributionManagement>
  <repository>
    <id>maven-releases</id>
    <url>http://<jenkins-slave-elastic-ip>:8081/repository/maven-releases/</url>
  </repository>
  <snapshotRepository>
    <id>maven-snapshots</id>
    <url>http://<jenkins-slave-elastic-ip>:8081/repository/maven-snapshots/</url>
  </snapshotRepository>
</distributionManagement>
```

### 7.2 Option A — Push via the Jenkins pipeline (recommended)

The repo ships [`Jenkinsfile`](./Jenkinsfile). Create a **Pipeline** job in
Jenkins pointing at this repo (`Jenkinsfile` is picked up automatically).
It runs:

`Git Checkout → Maven Compile → Unit Tests → SonarQube Analysis → OWASP
Dependency Check → Maven Build → Publish to Nexus → Docker Build & Tag → Trivy
Scan → Docker Push → Kubernetes Deploy → Verify`

With parameters:

| Parameter          | Default        | Notes                                |
| ------------------ | -------------- | ------------------------------------ |
| `APP_VERSION`      | `1.0-SNAPSHOT` | Must match `todo-app-${version}.jar` |
| `GIT_BRANCH`       | `main`         | Branch to build                      |
| `DOCKER_IMAGE_TAG` | `latest`       | Extra tag pushed to Docker Hub       |

The **Publish to Nexus** stage uses the `nexus-artifact-uploader` plugin and
the `nexus-creds` credential to upload
`target/todo-app-1.0-SNAPSHOT.jar` to the `maven-snapshots` repository at
`http://<jenkins-slave-elastic-ip>:8081`.

> Until Phase 6 the **Kubernetes Deploy / Verify** stages will fail — that is
> expected; build the `Publish to Nexus` portion first, then re-run the full
> pipeline after Phase 6.

### 7.3 Option B — Manual `mvn deploy`

If you only need the artifact in Nexus (no Jenkins yet):

```sh
# On your local machine or the Jenkins slave
mvn clean package
mvn deploy:deploy-file \
  -Dfile=target/todo-app-1.0-SNAPSHOT.jar \
  -DgroupId=com.example.todo \
  -DartifactId=todo-app \
  -Dversion=1.0-SNAPSHOT \
  -Dpackaging=jar \
  -DrepositoryId=maven-snapshots \
  -Durl=http://<jenkins-slave-elastic-ip>:8081/repository/maven-snapshots/
```

Verify in Nexus → **Browse → maven-snapshots** that `todo-app-1.0-SNAPSHOT.jar`
is listed.

---

## 8. Phase 5 — Provision the Kubernetes cluster when you are ready

When you are ready to deploy, enable the Kubernetes module and re-apply
Terraform (no `-target` needed):

```sh
cd terraform

# one-off
terraform apply -var="enable_kubernetes=true"

# or permanently
echo 'enable_kubernetes = true' >> terraform.tfvars
terraform apply --auto-approve
```

**What gets created now**

- `kubernetes_instance_count` EC2 nodes (default 3) + one Elastic IP each:

| Node index | Hostname                 | Role                                                      |
| ---------- | ------------------------ | --------------------------------------------------------- |
| 0          | `kubernetes-master`      | Control plane — `kubeadm init`, Calico CNI, NGINX Ingress |
| 1..N       | `kubernetes-worker-01` … | Workers — join via SSM-published token                    |

- An **IAM role/policy** scoped to the SSM parameter `/kubernetes/join-command`
  (least privilege: `ssm:GetParameter` / `ssm:PutParameter` only). The master
  publishes the `kubeadm join` command there; workers poll it and join once the
  API server is healthy.

**Important:** the security group already opens everything Kubernetes needs —
`6443` (API server), `30000–32768` (NodePort), plus internet egress.

**Read the outputs:**

```sh
terraform output kubernetes_node_public_ips
terraform output kubernetes_node_elastic_ips
terraform output kubernetes_node_ssh_commands
terraform output kubernetes_join_ssm_parameter
```

**Verify the cluster** from the master:

> Wait a few minutes before SSHing in — each node runs its `user_data`
> bootstrap (system prep, containerd, `kubeadm init`/`join`, Calico, Ingress)
> on first boot, and the workers need to poll SSM for the join command. Allow
> several minutes for the whole cluster to come up.

```sh
ssh -i <key_name>.pem ubuntu@<kubernetes-master-elastic-ip>
export KUBECONFIG=/home/ubuntu/.kube/config
kubectl get nodes -o wide           # master + workers all Ready (2–4 min)
kubectl get pods -A                 # calico + ingress-nginx Running
```

For detailed verification, troubleshooting, and first-login checks see:

- [`terraform/modules/kubernetes/KUBERNETES_SETUP.md`](./terraform/modules/kubernetes/KUBERNETES_SETUP.md)
- [`terraform/modules/kubernetes/KUBERNETES_FIRST_LOGIN.md`](./terraform/modules/kubernetes/KUBERNETES_FIRST_LOGIN.md)
- [`terraform/modules/kubernetes/CHECKING_THE_APP.md`](./terraform/modules/kubernetes/CHECKING_THE_APP.md)

---

## 9. Phase 6 — RBAC for the pipeline and deploy the app

### 9.1 Create the namespace and RBAC

The repo ships ready-to-apply manifests in [`kubernetes/`](./kubernetes). From
the master (or any host with a kubeconfig):

```sh
kubectl create namespace webapps                            # if it doesn't exist
kubectl apply -f kubernetes/service-account.yaml            # 1) identity
kubectl apply -f kubernetes/jenkins-token-secret.yaml       # 2) long-lived token
kubectl apply -f kubernetes/role.yaml                       # 3) permissions (webapps)
kubectl apply -f kubernetes/role-binding.yaml               # 4) bind role
```

See [`kubernetes/APPLY.md`](./kubernetes/APPLY.md) for the full guide, and
[`RBAC.md`](./RBAC.md) for a cluster-scoped variant (PVCs, StorageClasses).

### 9.2 Verify and capture the token

```sh
kubectl get sa,secret,role,rolebinding -n webapps
kubectl get secret jenkins-token -n webapps -o jsonpath='{.data.token}' | base64 -d
```

Store the printed token as the **`k8s-token`** Jenkins credential (Secret text).

### 9.3 Point the `Jenkinsfile` at the cluster

In [`Jenkinsfile`](./Jenkinsfile), `Kubernetes Deploy` uses:

```groovy
KUBE_CREDS_ID = 'k8s-token'
KUBE_MANIFEST = 'deployment-service.yml'
serverUrl: 'https://<kubernetes-master-private-ip>:6443'
namespace: 'webapps'
```

Replace `serverUrl` with the master's **private** IP (find it with
`kubectl get nodes -o wide`, or
`terraform output kubernetes_node_public_ips`). Private IPs only, because the
workers and pipeline reach the API server inside the VPC — the SG allows it.

### 9.4 Deploy the app

The manifests in [`deployment-service.yml`](./deployment-service.yml) are:

- **Deployment** `taskmaster-deployment` — 2 replicas, image
  `c0dechamp/prodtaskmaster:latest`, container port `8080`
- **Service** `taskmaster-svc` — `LoadBalancer`, port `80 → 8080`

Run the Jenkins pipeline end-to-end. On success, the K8s stage applies the
manifest and waits for rollout. Verify:

```sh
kubectl get all -n webapps
kubectl get svc taskmaster-svc -n webapps       # note the NodePort, e.g. 80:31263/TCP
curl http://<kubernetes-node-elastic-ip>:31263   # app HTML
```

> In a self-managed kubeadm cluster the Service `EXTERNAL-IP` stays
> `<pending>` — that's normal. The auto-assigned `nodePort` (`31263`) is the
> public entry point.

Full app-checking commands are in
[`terraform/modules/kubernetes/CHECKING_THE_APP.md`](./terraform/modules/kubernetes/CHECKING_THE_APP.md).

---

## 10. Teardown

Keep the cluster while removing infrastructure selectively:

```sh
cd terraform

# Remove only the Kubernetes nodes
terraform destroy -target="module.kubernetes[0]" --auto-approve

# Remove everything (network + Jenkins + Kubernetes)
terraform destroy --auto-approve
```

---

## 11. Reference

### Security group ports

| Port(s)     | Protocol | Purpose                                              |
| ----------- | -------- | ---------------------------------------------------- |
| 22          | TCP      | SSH                                                  |
| 80          | TCP      | HTTP                                                 |
| 443         | TCP      | HTTPS                                                |
| 25 / 465    | TCP      | SMTP / SMTPS                                         |
| 6443        | TCP      | Kubernetes API server                                |
| 3000–10000  | TCP      | Application port range (Sonar 9000, Nexus 8081, app) |
| 30000–32768 | TCP      | Kubernetes NodePort range                            |
| all         | egress   | Outbound anywhere                                    |

### Service map

| Service        | URL                                       | Port      |
| -------------- | ----------------------------------------- | --------- |
| Jenkins        | `http://<jenkins-server-eip>:8080`        | 8080      |
| SonarQube      | `http://<jenkins-slave-eip>:9000`         | 9000      |
| Nexus          | `http://<jenkins-slave-eip>:8081`         | 8081      |
| App (NodePort) | `http://<kubernetes-node-eip>:<nodePort>` | 80 → 8080 |

### Key files

- [`Jenkinsfile`](./Jenkinsfile) — CI/CD pipeline
- [`deployment-service.yml`](./deployment-service.yml) — K8s Deployment + Service
- [`kubernetes/`](./kubernetes) — RBAC manifests + apply guide
- [`RBAC.md`](./RBAC.md) — RBAC reference (incl. cluster-scoped)
- [`terraform/`](./terraform) — all infrastructure as code