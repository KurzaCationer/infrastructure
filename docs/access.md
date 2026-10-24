# Access

Requires a checkout at the deployed commit, Terraform, kubectl, AWS authentication
and a tailnet connection. Set `TF_STATE_BUCKET` and `AWS_REGION`, or authenticate
`gh` to read them from the repository variables.

AWS access must allow listing the state bucket, reading cluster state and
decrypting it when a customer-managed KMS key is used. `AWS_PROFILE` is supported.

From the repository root:

```sh
bash scripts/check-cluster.sh
export KUBECONFIG="$HOME/.kube/kurza-infrastructure.yaml"
```

Windows PowerShell:

```powershell
.\scripts\check-cluster.bat
$env:KUBECONFIG = "$env:USERPROFILE\.kube\kurza-infrastructure.yaml"
```

Expect one Ready node and a healthy Cilium rollout. Rerun after node replacement
to refresh the admin kubeconfig. Use absolute paths for `CLUSTER_DIR` and
`KUBECONFIG_PATH` overrides.

SSH uses the hostname printed by the check script and the deployment private key:

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
