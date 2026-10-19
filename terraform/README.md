# Terraform

The layers run in order: **cluster -> bootstrap**. Both use the existing S3 bucket
with separate state keys and native S3 locking. CI uses Terraform 1.16.6.

- `cluster`: Kube-Hetzner 3.2.1 with one schedulable `cx23` control-plane node in
  `nbg1`, running k3s and workloads together. No worker nodes. Automatic upgrades
  are disabled. Cilium supplies the CNI, kube-proxy replacement, and Gateway API
  controller; Traefik is disabled. The Cilium operator runs one replica.
- `bootstrap`: empty, ready for cluster services later. No Kubernetes operator or
  application secrets are installed yet.

This is a small, non-HA starting point. Nodes enroll into Tailscale during
cloud-init. Public SSH and Kubernetes API firewall rules are disabled;
Terraform and operators connect using the node's tailnet MagicDNS name.
Nodes retain public addresses for outbound bootstrap and Tailscale connectivity.

## Private node access with Tailscale

This uses the module's native `node_transport_mode = "tailscale"` integration,
following its [Tailscale example](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/tree/v3.2.1/examples/tailscale-node-transport).
**Kube-Hetzner 3.2.1 marks Cilium with Tailscale transport as experimental**;
`enable_experimental_cilium = true` is deliberately enabled to retain Cilium and
Gateway API. This combination still needs live verification before production use.

Configure the tailnet before the first deployment:

1. Enable MagicDNS and record the tailnet's `*.ts.net` domain.
2. Define tags `tag:kurza-cluster` and `tag:ci` with appropriate tag owners.
3. Create a Tailscale federated identity for node enrollment with writable
   `auth_keys` scope, restricted to `tag:kurza-cluster`. Restrict the GitHub
   issuer/subject to this repository's default branch. Save its client ID and
   configured audience as `TS_NODE_CLIENT_ID` and `TS_NODE_AUDIENCE`.
4. Create a Tailscale federated identity for GitHub Actions with writable
   `auth_keys` scope and `tag:ci`. Restrict its GitHub issuer/subject to this
   repository's default branch. Set its client ID and configured audience as
   `TS_CLIENT_ID` and `TS_AUDIENCE`. The cluster runner joins as an ephemeral CI
   device through OIDC, then logs out after the job; no runner auth key is stored.
5. Permit your users and `tag:ci` to reach `tag:kurza-cluster` on TCP 22 and 6443
   in the tailnet policy. Node-internal Kubernetes networking remains on the
   Hetzner private network. Subnet route advertisements are disabled for this
   single-network cluster, so route approval is not required.

Each cluster deployment exchanges a GitHub OIDC token for a short-lived Tailscale
API token and creates a reusable, preapproved enrollment key with a **one-hour**
lifetime. The key registers durable nodes (`ephemeral = false`) with
`tag:kurza-cluster`. It is masked and passed to Terraform through
`TF_VAR_tailscale_auth_key`, without reading or writing it in Bitwarden.

After apply, an `always()` cleanup step requests fresh federated credentials and
revokes the key, including when plan/apply fails. Revocation errors fail the
cleanup step. If the runner is forcibly terminated or cleanup cannot complete,
the one-hour expiry limits the key's remaining lifetime. Deployment jobs have a
50-minute timeout to stay within the enrollment window. Revocation does not
disconnect nodes already enrolled.

Existing static nodes are not replaced just because the enrollment key changes:
the pinned upstream host module ignores changes to cloud-init `user_data`.
New or deliberately replaced nodes receive the current run's key.

SSH uses the existing SSH private key over Tailscale. Tailscale SSH is not enabled,
so no separate Tailscale SSH policy is required. Kubernetes retains its kubeconfig
authentication, with the API endpoint set to the first control plane's MagicDNS
name by the module. Connect your workstation to the tailnet before running SSH,
kubectl, or Terraform. A local Terraform run needs
`TF_VAR_tailscale_magicdns_domain` or the equivalent `.tfvars` setting.
For local plans/applies, also supply a fresh short-lived node enrollment key as
`TF_VAR_tailscale_auth_key` and revoke it afterward. The federation helper requires
the GitHub Actions OIDC environment and is intended to run inside the workflow.

After applying, get the private SSH hostname with
`terraform -chdir=terraform/cluster output -raw control_plane_hostname`, then
connect with `ssh -i /path/to/private-key root@<hostname>`. The existing sensitive
`kubeconfig` output contains the private Kubernetes API endpoint.

The node enrollment key can enter Terraform state and Hetzner cloud-init user
data. Restrict state/project access.

## One-time prerequisites

1. Create an S3 state bucket with versioning, encryption, and public access blocked.
2. Configure GitHub OIDC trust for the default branch on the existing role:
   `arn:aws:iam::154009488279:role/kurza-infrastructure-github-actions-role`.
   Trust audience `sts.amazonaws.com` and the repository's actual OIDC subject.
3. Give the role `s3:ListBucket` on the bucket for `cluster/*` and `bootstrap/*`,
   `s3:GetObject`/`s3:PutObject` on each `terraform.tfstate` object, and
   `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on each `.tfstate.tflock` object.
   A customer-managed KMS key also needs appropriate key permissions.
4. Prepare **Leap Micro snapshots for k3s** in the Hetzner project using
   [`cluster/hcloud-init`](cluster/hcloud-init/README.md). The repository includes
   the pinned upstream templates, signing keys, and verification scripts for x86
   and ARM. Terraform selects the latest matching snapshot automatically.
5. Store a Hetzner project Read & Write API token, SSH public key, and matching
   unencrypted SSH private key in Bitwarden Secrets Manager.
   Give a machine account read access to these secrets and create an access token.

For the snapshots, install Packer **1.16.0**, export `HCLOUD_TOKEN`, and run:

```sh
cd terraform/cluster/hcloud-init
bash build.sh
```

Alternatively, manually run **Hcloud init** in GitHub Actions and select x86,
ARM, or both. It retrieves the Hetzner token using the Bitwarden GitHub Action
and the existing repository settings. It is never triggered automatically.

The image builds create temporary servers and billable snapshots in Hetzner.
They are a separate, deliberate initialization step; GitHub deployment runs do
not rebuild images automatically. No Terraform module download is needed first.

## Ingress with Cilium

The module installs Cilium's Gateway API controller and the standard Gateway API
CRDs. Application manifests can define a `Gateway` with `gatewayClassName: cilium`
and attach `HTTPRoute` resources. No Gateway, domain, certificate, or application
route is created yet. This follows the module's
[Cilium Gateway API example](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/tree/v3.2.1/examples/cilium-gateway-api).

By default, a Cilium Gateway creates a `LoadBalancer` Service, which Hetzner CCM
backs with a billable external load balancer. The controller itself does not
create one until a Gateway is configured. The module's single-node setup also
enables k3s ServiceLB; choose the exposure configuration when adding your Gateway.

## GitHub configuration

In Settings > Secrets and variables > Actions, configure:

| Type | Name | Value |
| --- | --- | --- |
| Variable | `TF_STATE_BUCKET` | Existing state bucket name |
| Variable | `AWS_REGION` | Bucket's AWS region |
| Variable | `AWS_IAM_ROLE` | AWS role ARN assumed through GitHub OIDC |
| Secret | `BWS_ACCESS_TOKEN` | Bitwarden machine-account access token |
| Variable | `BW_ORGANIZATION_ID` | Bitwarden organization UUID |
| Variable | `BW_SECRET_IDS` | JSON object shown below, containing secret UUIDs |
| Variable | `TS_MAGICDNS_DOMAIN` | Tailnet domain, for example `example-tailnet.ts.net` |
| Variable | `TS_CLIENT_ID` | Tailscale federated identity client ID for the cluster workflow |
| Variable | `TS_AUDIENCE` | Audience configured on that Tailscale federated identity |
| Variable | `TS_NODE_CLIENT_ID` | Separate federated identity client ID restricted to `tag:kurza-cluster` |
| Variable | `TS_NODE_AUDIENCE` | Audience configured on the node enrollment federated identity |
| Variable | `BW_API_URL` | Optional; defaults to `https://api.bitwarden.com` |
| Variable | `BW_IDENTITY_API_URL` | Optional; defaults to `https://identity.bitwarden.com` |

```json
{
  "hcloud_token": "YOUR_HETZNER_TOKEN_SECRET_UUID",
  "ssh_public_key": "YOUR_PUBLIC_KEY_SECRET_UUID",
  "ssh_private_key": "YOUR_PRIVATE_KEY_SECRET_UUID"
}
```

For Bitwarden EU, set the two endpoint variables to `https://api.bitwarden.eu`
and `https://identity.bitwarden.eu`, respectively.

The workflow exposes the existing `BWS_ACCESS_TOKEN` secret as `BW_ACCESS_TOKEN`,
which is the Terraform provider's environment variable. The cluster deployment
fetches secret values directly through Terraform. Only the separate Packer
workflow uses the Bitwarden GitHub Action. Bootstrap does not receive the
Bitwarden access token.

Bitwarden data-source values and the admin kubeconfig are stored in Terraform
state and saved plans. Restrict state access accordingly; marking a value sensitive
only hides it in ordinary output. Plans are applied within the job and are not
uploaded as artifacts.

## Running

Pull requests run formatting and validation for both layers without accessing AWS,
Bitwarden, or Tailscale. In Actions, choose **Terraform > Run workflow** on the default branch
to plan and apply cluster, then bootstrap. Pushes do not deploy. Runs on other
branches only validate. Deployments are serialized and active applies are not
cancelled. Running the deployment creates billable Hetzner resources.

To tear down the infrastructure, choose **Terraform destroy > Run workflow** on
the default branch and enter `destroy` in the confirmation input. This workflow
only runs manually. It destroys **bootstrap -> cluster**, stopping if either
layer fails, and shares the deployment concurrency lock so deploy and destroy
cannot overlap. Each layer creates a saved destroy plan and applies that plan
using the same backend, credentials, and private network access as deployment.
The cluster job also reuses the short-lived enrollment-key creation and revocation
lifecycle, so the same node federation settings are required.

Destruction removes resources managed by these Terraform states. The existing S3
state bucket and separately built Hetzner snapshots remain.

To validate locally without credentials:

```sh
terraform fmt -check -recursive terraform
terraform -chdir=terraform/cluster init -backend=false
terraform -chdir=terraform/cluster validate
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap validate
```

## Verify a deployment locally

After GitHub applies, update your checkout to the deployed commit. Have Terraform
1.16.6 or newer, Tailscale, and kubectl installed, with AWS credentials already
available and your workstation already connected to the tailnet. The scripts do
not log into AWS or Tailscale and do not require Bitwarden credentials or a node
enrollment key.

From the repository root, run:

```sh
# Linux / Bash
bash scripts/check-cluster.sh
```

```bat
rem Windows / CMD (also callable from PowerShell)
scripts\check-cluster.bat
```

Both scripts work from other directories when called by their full path.

Both have a matching **Configuration** section at the top. Edit the defaults
there, or set the same environment variables before running either script:

| Variable | Default |
| --- | --- |
| `REPOSITORY` | `KurzaCationer/infrastructure` |
| `CLUSTER_DIR` | This checkout's `terraform/cluster` directory |
| `TF_STATE_BUCKET` | Read from GitHub when blank |
| `AWS_REGION` | Read from GitHub when blank |
| `KUBECONFIG_PATH` | Your home directory's `.kube/kurza.yaml` |
| `SYSTEM_NAMESPACE` | `kube-system` |
| `GATEWAY_CLASS` | `cilium` |
| `REQUEST_TIMEOUT` | `30s` |
| `ROLLOUT_TIMEOUT` | `120s` |

For example, the same override on Linux and Windows:

```sh
export REQUEST_TIMEOUT=60s
bash scripts/check-cluster.sh
```

```bat
set "REQUEST_TIMEOUT=60s"
scripts\check-cluster.bat
```

Use an absolute path when overriding `CLUSTER_DIR` or `KUBECONFIG_PATH` to keep
behavior independent of the directory from which you launch the script.

The scripts:

1. Read `TF_STATE_BUCKET` and `AWS_REGION` from your environment, falling back to
   the repository's GitHub variables through the authenticated `gh` CLI.
2. Initialize `terraform/cluster` against the same S3 state GitHub uses and list
   recorded resources.
3. Save the admin kubeconfig as `~/.kube/kurza.yaml` on Linux or
   `%USERPROFILE%\.kube\kurza.yaml` on Windows. Failed output retrieval preserves
   any existing kubeconfig at that path.
4. Show Tailscale status and check connectivity to the private MagicDNS hostname.
5. Query live cluster information, nodes, pods, Cilium rollout health, and the
   Cilium GatewayClass. A failed command returns a nonzero exit code.

Your AWS identity must be able to list the state bucket and read its state
object, plus decrypt it if a customer-managed KMS key is used. GitHub's OIDC role
does not authenticate the workstation. Set `AWS_PROFILE` beforehand if needed;
the scripts use the existing AWS credential chain. If both backend environment
variables are set, `gh` is not required.

Expect one `Ready` node and healthy system pods. Review the pod listing for
pending or crashing workloads. The scripts use the dedicated kubeconfig explicitly
for their checks and print how to select it for subsequent kubectl commands;
they do not replace your default kubeconfig. Keep the saved file private: it
grants admin access to the cluster.

The scripts only inspect saved state and query the live cluster. They do not run
Terraform plan/apply/refresh or start an interactive SSH session. For SSH, use the
printed hostname with your deployment private key:

```sh
ssh -i /path/to/private-key root@<hostname>
```

Run the script again after cluster replacement or credential changes to update
the local kubeconfig. Repeat backend initialization and `state list` separately
for `terraform/bootstrap` when that layer manages resources.

## Local Terraform plans and applies

For local plans/applies, authenticate to AWS, export `BW_ACCESS_TOKEN`,
`BW_ORGANIZATION_ID`, `BW_API_URL`, and `BW_IDENTITY_API_URL`, and put the secret-ID
object in `TF_VAR_bitwarden_secret_ids` or a gitignored `terraform.tfvars` file.
Optional Terraform variables `cluster_name`, `location`, and `server_type` default
to `kurza`, `nbg1`, and `cx23`. Location must stay in `eu-central`. Set `server_type`
to a `cax` type (for example, `cax11`) for ARM; other types select x86. Build the
matching snapshot first. Changing architecture replaces the node; this single-node
setup has no redundancy during replacement or maintenance.

```sh
terraform -chdir=terraform/cluster init -reconfigure -backend-config="bucket=YOUR_BUCKET" -backend-config="region=YOUR_REGION"
terraform -chdir=terraform/cluster plan
```

The module does not write kubeconfig or kustomization files during CI runs.

Commit the provider lock file. State, local variable files, plans, and
`.terraform/` directories are ignored.

References: [Kube-Hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner),
[Bitwarden provider](https://bitwarden.com/help/terraform-provider/),
[S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3),
[AWS OIDC action](https://github.com/aws-actions/configure-aws-credentials),
[Tailscale federation](https://tailscale.com/docs/features/workload-identity-federation),
[Terraform outputs](https://developer.hashicorp.com/terraform/cli/commands/output),
[Kubernetes cluster checks](https://kubernetes.io/docs/tasks/debug/debug-cluster/).
