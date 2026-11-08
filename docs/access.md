# Access

Health checks require kubectl and a tailnet connection. Kubeconfig retrieval also
requires Terraform, AWS authentication and a checkout at the deployed commit.
Set `TF_STATE_BUCKET` and `AWS_REGION`, or authenticate `gh` to read them from
the repository variables.

AWS access must allow listing the state bucket, reading cluster state and
decrypting it when a customer-managed KMS key is used. `AWS_PROFILE` is supported.

## Kubeconfig

Retrieve or refresh the admin kubeconfig from the repository root:

```sh
bash scripts/get-kubeconfig.sh
export KUBECONFIG="$HOME/.kube/kurza-infrastructure.yaml"
```

Windows PowerShell:

```powershell
.\scripts\get-kubeconfig.bat
$env:KUBECONFIG = "$env:USERPROFILE\.kube\kurza-infrastructure.yaml"
```

Run retrieval again after node replacement or credential changes. Failed retrieval
preserves the existing file. Use absolute paths for `CLUSTER_DIR` and
`KUBECONFIG_PATH` overrides.

## Showcase portfolio kubeconfig

After retrieving the admin kubeconfig above, run locally with PowerShell (or
`pwsh` on Linux/macOS), while connected to Tailscale:

```powershell
.\scripts\get-showcase-portfolio-kubeconfig.ps1
kubectl --kubeconfig "$HOME/.kube/showcase-portfolio.yaml" get pods
```

The script creates `showcase-portfolio` if missing and applies a dedicated
ServiceAccount, Role and RoleBinding in that namespace. It grants management of
workloads, services, configuration, Secrets, ServiceAccounts, storage claims,
ingresses, network policies and HTTP/gRPC routes, including logs, exec and port
forwarding. It grants no RBAC administration or cluster-scoped permissions.
Custom resources beyond those listed in the script are not included.

Each run retrieves the same persistent ServiceAccount token from the cluster
and rebuilds the local kubeconfig; the token Secret is created only if missing.
This uses Kubernetes' [manually created ServiceAccount token Secret](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#manually-create-a-long-lived-api-token-for-a-serviceaccount)
mechanism. The token has no automatic expiry; protect the generated file.
Workload and Secret access permits using other ServiceAccounts in this namespace,
so avoid placing more privileged identities there.

Use `-AdminKubeconfig <path>` and `-OutputPath <path>` to override the defaults.
The admin kubeconfig is required on every run; the generated kubeconfig cannot
manage its own Role or RoleBinding. The script does not change your current
kubeconfig context. It restricts the output file to the current OS user and does
not print credentials. Generate again after replacing the cluster.

## Health checks

```sh
bash scripts/check-cluster.sh
```

```powershell
.\scripts\check-cluster.bat
```

Checks reuse the kubeconfig, retrieving it automatically if missing or empty.
An existing kubeconfig requires no Terraform, AWS or GitHub access.

Checks cover node readiness, Cilium, platform deployments, Argo CD application
sync and health, certificates and the public Gateway. Run after all layers are
deployed. A failed check exits nonzero. Override `REQUEST_TIMEOUT` (default `30s`)
or `ROLLOUT_TIMEOUT` (default `120s`) for slower connections or rollouts.

SSH uses the deployment private key and the hostname in the kubeconfig's API URL:

```sh
ssh -i /path/to/private-key root@<hostname>
```

## Argo CD

Open `https://argocd.<your-tailnet>.ts.net` through Tailscale.
For SSO, complete [Pocket ID enrollment](pocket-id.md#administrator-enrollment).

For initial local admin access, retrieve the password in a local terminal:

```sh
argocd admin initial-password -n argocd
argocd login argocd.<your-tailnet>.ts.net --grpc-web
argocd account update-password --grpc-web
kubectl -n argocd delete secret argocd-initial-admin-secret
```

The CLI requires `--grpc-web`. Retain local admin access for recovery.

If the ingress has no address, check Tailscale operator logs, Service host
approval, MagicDNS, HTTPS certificates and tailnet grants.
