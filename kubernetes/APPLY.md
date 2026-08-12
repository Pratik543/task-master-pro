# Applying the Kubernetes RBAC Files for Jenkins

This guide explains how to apply the Kubernetes manifests in this `kubernetes/` directory. They set up a **namespace-scoped** service account that lets the Jenkins pipeline deploy and manage the app inside the `webapps` namespace only.

## What each file does

| File | Kind | Object name | Purpose |
| --- | --- | --- | --- |
| `service-account.yaml` | ServiceAccount | `jenkins` | Identity the pipeline uses to talk to the cluster |
| `jenkins-token-secret.yaml` | Secret | `jenkins-token` | Long-lived token for the `jenkins` service account |
| `role.yaml` | Role | `app-role` | Permissions on app resources (pods, deployments, services, secrets, PVCs) **inside `webapps`** |
| `role-binding.yaml` | RoleBinding | `app-rolebinding` | Binds `app-role` to the `jenkins` service account |

All resources are scoped to the `webapps` namespace (a `Role`, not a `ClusterRole`) — the pipeline can only touch that namespace. (See repo-root `RBAC.md` for the same objects plus an optional cluster-scoped variant.)

## 1. Prerequisites

From the Kubernetes master node (or any host with the kubeconfig):

```bash
export KUBECONFIG=/home/ubuntu/.kube/config
kubectl cluster-info
```

### Make sure the namespace exists

These files target `webapps`, so it must exist first. Create it if not present:

```bash
kubectl get ns webapps
kubectl create namespace webapps
```

## 2. Apply order

Order matters here because the token secret references the service account and the role binding references the role.

```bash
# 1) Identity
kubectl apply -f service-account.yaml

# 2) Token for that identity
kubectl apply -f jenkins-token-secret.yaml

# 3) Permissions
kubectl apply -f role.yaml

# 4) Attach permissions to the identity
kubectl apply -f role-binding.yaml
```

Or apply everything from the directory in one shot:

```bash
kubectl apply -f kubernetes/
```

## 3. Verification

```bash
kubectl get sa,secret,role,rolebinding -n webapps

# Confirm the token was actually populated (not empty)
kubectl get secret jenkins-token -n webapps -o jsonpath='{.data.token}' | base64 -d | wc
```

**Expected:** you see `jenkins` (service account), `jenkins-token` (secret), `app-role` (role) and `app-rolebinding` (role binding) listed. `wc` shows a token length well above zero.

### Check the pipeline can act as the service account

```bash
# Who can do what as the jenkins SA:
kubectl auth can-i --list --as=system:serviceaccount:webapps:jenkins -n webapps
```

## 4. Use the token in Jenkins

Extract the token and store it as the `k8s-token` credential in Jenkins:

```bash
kubectl -n webapps describe secret mysecretname # or below command
kubectl get secret jenkins-token -n webapps -o jsonpath='{.data.token}' | base64 -d
```

Paste the output into Jenkins credentials (id `k8s-token`) — either as a **Secret text** token, or embedded in a full **Secret file** kubeconfig (`serverUrl: https://<master-ip>:6443`, `certificate-authority-data` from the master's `/etc/kubernetes/pki/ca.crt`) if your pipeline uses `withKubeConfig`.

## 5. Update / delete

```bash
# Re-apply after editing any manifest
kubectl apply -f kubernetes/

# Remove everything created by these files
kubectl delete -f kubernetes/
```

