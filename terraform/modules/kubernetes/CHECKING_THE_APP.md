# Checking the Running Application — Kubernetes Commands

This guide shows exactly how to verify the Task Master app that the CI/CD pipeline deploys to the Kubernetes cluster, using `kubectl` and a handful of AWS commands.

## What is deployed

The pipeline's **Kubernetes Deploy** stage applies `deployment-service.yml` (in the repo root) via a kubeconfig whose context points at namespace `webapps`. It defines:

| Resource | Name | Details |
| --- | --- | --- |
| Deployment | `taskmaster-deployment` | 2 replicas, image `c0dechamp/prodtaskmaster:latest`, container port `8080` |
| Service | `taskmaster-svc` | `type: LoadBalancer`, port `80` → targetPort `8080` |

Because the app lives in the `webapps` namespace, **every** `kubectl` command below needs `-n webapps`.

---

## 1. Prerequisites

These commands run from a host that has `kubectl` and a kubeconfig for the cluster. The easiest place is the Kubernetes master node:

```bash
ssh -i <your-key.pem> ubuntu@<kubernetes-master-elastic-ip>
```

Then make kubectl pick up the kubeconfig that the bootstrap script created for the `ubuntu` user:

```bash
export KUBECONFIG=/home/ubuntu/.kube/config

# Optional: shorthand
alias k="kubectl"
```

Verify the connection:

```bash
kubectl cluster-info
```

> If the master node isn't reachable directly, you can also run these on the Jenkins master node (same VPC) using the kubeconfig from the Jenkins credential store, or via `kubectl` inside a pipeline build.

---

## 2. Cluster and namespace overview

```bash
# Are all nodes Ready? (master + workers)
kubectl get nodes -o wide

# What namespaces exist? (webapps should be present)
kubectl get ns

# One-liner: everything running in the app namespace
kubectl get all -n webapps
```

**Expected:** all nodes show `Ready`; `webapps` is listed; `get all` shows the deployment, the 2 pods (Running), a ReplicaSet, and `service/taskmaster-svc`.

---

## 3. Check the Deployment and Pods

```bash
kubectl get deploy taskmaster-deployment -n webapps -o wide
kubectl get pods -n webapps -o wide
```

`-o wide` adds the node and pod IPs — useful to see which node each replica landed on.

For fine detail:

```bash
kubectl describe deploy taskmaster-deployment -n webapps
kubectl describe pod -n webapps <pod-name>
```

**Expected:** `AVAILABLE 2/2`, `READY 2/2` for pods, `STATUS Running`.

---

## 4. Check the Service

```bash
kubectl get svc taskmaster-svc -n webapps -o wide
kubectl get svc taskmaster-svc -n webapps -o yaml
```

You will see output like:

```
NAME            TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
taskmaster-svc  LoadBalancer   10.101.47.19   <pending>     80:31263/TCP   33m
```

Two things to understand:

- **`EXTERNAL-IP: <pending>`** — this is **normal**. The cluster is self-managed (kubeadm, no cloud load balancer), so an external load-balancer IP can never be assigned. It is *not* a failure.
- **`80:31263/TCP`** — Kubernetes auto-assigns a **nodePort** (`31263`) even to LoadBalancer services. This is the real way traffic reaches the app from outside: `http://<node-IP>:31263`.

---

## 5. Test the app internally (from the master)

The app listens on port `8080` inside the pod. Any of these proves the app is serving:

```bash
# Directly against a pod IP (from step 3)
curl http://<pod-ip>:8080

# Against the Service's CLUSTER-IP on port 80
curl http://10.101.47.19:80

# Against the nodePort on the local machine's own IP
echo "http://$(curl -s ifconfig.me):31263"
curl http://172.31.8.162:31263
```

**Expected:** the app's HTML (or JSON/response) – not a connection error.

---

## 6. Get the public link

The cluster nodes each have an **Elastic IP**, and the security group already opens the NodePort range (`30000–32768`) to the internet. Find the public IPs from your local machine (where Terraform state lives):

```bash
terraform output kubernetes_node_elastic_ips
```

Or in the AWS Console: **EC2 → Elastic IPs →** note the addresses attached to the `Kubernetes-Node-EIP-0*` entries.

Then open in a browser:

```
http://<any-kubernetes-node-elastic-ip>:31263
```

> The exact port (`31263`) is random and can change if the Service is recreated. To make it fixed, patch the Service, e.g. `nodePort: 30080`, then use that port instead.

---

## 7. Local-only access (no public IP needed)

If you just want to see it locally without any node IP:

```bash
kubectl port-forward -n webapps svc/taskmaster-svc 8080:80
```

Then open `http://localhost:8080` in a browser. (The forward maps local `8080` → Service port `80` → pod `8080`.)

---

## 8. Logs and troubleshooting

```bash
# Stream/replay app logs
kubectl logs -n webapps deploy/taskmaster-deployment --tail=50
kubectl logs -n webapps <pod-name> --follow

# Recent cluster events (image pull failures, scheduling, etc.)
kubectl get events -n webapps --sort-by=.lastTimestamp

# Restart the deployment (rolling restart)
kubectl rollout restart deployment/taskmaster-deployment -n webapps
kubectl rollout status deployment/taskmaster-deployment -n webapps

# Force an image re-pull on existing pods
kubectl rollout restart deployment/taskmaster-deployment -n webapps
```

**Common gotcha — `ImagePullBackOff`:** if the output shows the pod stuck pulling the image, the Docker Hub repo `c0dechamp/prodtaskmaster` is probably **private**. The pipeline's push credentials do not grant pull access to the cluster. Fix: create an `imagePullSecret` in the `webapps` namespace and reference it in `deployment-service.yml`.

---

## 9. Quick reference (copy-paste block)

```bash
export KUBECONFIG=/home/ubuntu/.kube/config

kubectl get nodes -o wide
kubectl get all -n webapps
kubectl get pods -n webapps -o wide
kubectl get svc taskmaster-svc -n webapps
kubectl rollout status deployment/taskmaster-deployment -n webapps
curl http://localhost:31263
```
