# Access and verification

[Home](../README.md) · [Setup](setup.md) · [Access](access.md) · [Architecture](architecture.md) · [Operations](operations.md) · [Development](development.md) · [Security](security.md)

Requirements: checkout at the deployed commit, Terraform **>= 1.16.6, < 2.0**,
Tailscale, kubectl and an authenticated AWS session. The workstation must be
connected to the tailnet. Bitwarden credentials and enrollment keys are not
needed for these checks.

From the repository root:

```sh
# Linux / Bash
bash scripts/check-cluster.sh
```

```powershell
# Windows PowerShell; in CMD omit the leading .\
.\scripts\check-cluster.bat
```

Both scripts accept the same environment variables. Defaults are also defined
in the **Configuration** section of each script.

| Variable | Default |
| --- | --- |
| `REPOSITORY` | `KurzaCationer/infrastructure` |
| `CLUSTER_DIR` | This checkout's `terraform/cluster` directory |
| `TF_STATE_BUCKET` | Read from GitHub when blank |
| `AWS_REGION` | Read from GitHub when blank |
| `KUBECONFIG_PATH` | Home directory + `.kube/kurza-infrastructure.yaml` |
| `SYSTEM_NAMESPACE` | `kube-system` |
| `GATEWAY_CLASS` | `cilium` |
| `REQUEST_TIMEOUT` | `30s` |
| `ROLLOUT_TIMEOUT` | `120s` |

Timeout override:

```sh
export REQUEST_TIMEOUT=60s
bash scripts/check-cluster.sh
```

```bat
set "REQUEST_TIMEOUT=60s"
scripts\check-cluster.bat
```

`CLUSTER_DIR` and `KUBECONFIG_PATH` overrides should be absolute paths.

The scripts:

1. Read `TF_STATE_BUCKET` and `AWS_REGION` from the environment, falling back to
   the repository's GitHub variables through the authenticated `gh` CLI.
2. Initialize `terraform/cluster` against the same S3 state GitHub uses and list
   recorded resources.
3. Save the admin kubeconfig as `~/.kube/kurza-infrastructure.yaml` on Linux or
   `%USERPROFILE%\.kube\kurza-infrastructure.yaml` on Windows. Failed output retrieval preserves
   any existing kubeconfig at that path.
4. Show Tailscale status and check connectivity to the private MagicDNS hostname.
5. Query live cluster information, nodes, pods, Cilium rollout health, and the
   Cilium GatewayClass. A failed command returns a nonzero exit code.

AWS permissions: list the state bucket, read the state object and decrypt it
if a customer-managed KMS key is used. The scripts use the local AWS credential
chain, including `AWS_PROFILE`. With both backend variables set, `gh` is optional.

Expected result: one `Ready` node, healthy system pods and a healthy Cilium
rollout. The scripts save an admin kubeconfig separately from the default
kubeconfig and print the command to select it.

Checks read saved state and query the cluster without running plan, apply or
refresh. SSH uses the printed hostname and deployment private key:

```sh
ssh -i /path/to/private-key root@<hostname>
```

Run the script again after cluster replacement or credential changes to update
the local kubeconfig. Repeat backend initialization and `state list` separately
for `terraform/bootstrap` when that layer manages resources.

## Verify bootstrap and sign in

With the kubeconfig saved by the check script:

```sh
export KUBECONFIG="$HOME/.kube/kurza-infrastructure.yaml"
kubectl -n sm-operator-system get deployments
kubectl -n tailscale get bitwardensecret tailscale-operator-oauth
kubectl -n tailscale get secret operator-oauth
kubectl -n tailscale rollout status deployment/operator --timeout=180s
kubectl get proxygroup argocd-ingress
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
kubectl -n argocd get ingress argocd
kubectl -n argocd get services
```

In PowerShell, select the kubeconfig with
`$env:KUBECONFIG = "$env:USERPROFILE\.kube\kurza-infrastructure.yaml"` before the same kubectl commands.

Expected ingress ADDRESS: `argocd.<your-tailnet>.ts.net`. Services remain
`ClusterIP`. The initial login is `admin`; retrieve the password locally,
then change it and delete the initial password Secret:

```sh
argocd admin initial-password -n argocd
argocd login argocd.<your-tailnet>.ts.net --grpc-web
argocd account update-password --grpc-web
kubectl -n argocd delete secret argocd-initial-admin-secret
```

The CLI requires `--grpc-web` through the HTTPS proxy. Initial password retrieval
belongs in a local session, outside CI logs. Dex is disabled pending SSO configuration.

Argo CD should be reachable by an allowed tailnet identity and unreachable
outside the tailnet. `svc:argocd` and its approved host appear on the Tailscale
Services page. An empty ingress ADDRESS usually needs investigation in the
operator logs, Service approval, DNS, certificates or grants.
