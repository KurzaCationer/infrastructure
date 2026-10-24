# Setup

[Home](../README.md) · [Setup](setup.md) · [Access](access.md) · [Architecture](architecture.md) · [Operations](operations.md) · [Development](development.md) · [Security](security.md)

Initial setup for GitHub Actions deployments. The state bucket, credentials,
tailnet and matching base images must exist before the first apply.
Commands run from the repository root unless noted otherwise.

## 1. Prepare accounts, tools and AWS state

Required accounts: Hetzner Cloud, AWS, Bitwarden Secrets Manager and Tailscale,
plus access to the repository's GitHub Actions settings.

For local verification, install Terraform **>= 1.16.6, < 2.0**, Tailscale,
kubectl and the Argo CD CLI, and authenticate to AWS. `gh` can read
the backend settings from GitHub; otherwise set `TF_STATE_BUCKET` and `AWS_REGION`.
CI installs its own tools. For [local image builds](../terraform/cluster/hcloud-init/README.md#build-commands),
use Linux/WSL/macOS with Bash, Packer **1.16.0**, `curl`, `unzip` and `sha256sum`
(GNU coreutils on macOS).

1. Create an S3 state bucket with versioning, encryption, and public access blocked.
2. Configure GitHub OIDC trust for the default branch on the existing role:
   `arn:aws:iam::154009488279:role/kurza-infrastructure-github-actions-role`.
   Trust audience `sts.amazonaws.com` and the repository's actual OIDC subject.
3. Give the role `s3:ListBucket` on the bucket for `cluster/*`, `bootstrap/*` and `identity/*`,
   `s3:GetObject`/`s3:PutObject` on each layer's `terraform.tfstate` object, and
   `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on each lock object, for example
   `cluster/terraform.tfstate.tflock`, `bootstrap/terraform.tfstate.tflock` and
   `identity/terraform.tfstate.tflock`.
   A customer-managed KMS key also needs appropriate key permissions.
4. Store a Hetzner project Read & Write API token, SSH public key, and matching
   unencrypted SSH private key in Bitwarden Secrets Manager.
   Give a machine account read access to these secrets and create an access token.

The bucket and IAM role are managed outside this repository.
The reusable workflow restricts AWS authentication to account `154009488279`.
To use another account, update `allowed-account-ids` in
[`.github/workflows/terraform-layer.yml`](../.github/workflows/terraform-layer.yml)
as well as the role setting. The OIDC subject must match the default branch:
`repo:OWNER/REPOSITORY:ref:refs/heads/DEFAULT_BRANCH`.

## 2. Configure private node access

Cilium with Tailscale transport is experimental in Kube-Hetzner 3.2.1 and enabled
here for Gateway API support. Network details are in [architecture](architecture.md).

Tailnet configuration:

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
5. Permit administrators and `tag:ci` to reach `tag:kurza-cluster` on TCP 22 and 6443
   in the tailnet policy. Node-internal Kubernetes networking remains on the
   Hetzner private network. Subnet route advertisements are disabled for this
   single-network cluster, so route approval is not required.

CI creates a one-hour enrollment key for durable nodes and revokes it after each
run. SSH uses the deployment key over Tailscale; Kubernetes uses kubeconfig
authentication. Workstation access also requires a tailnet connection.
[Enrollment key cleanup](security.md#node-enrollment-lifecycle) runs in CI;
[local applies](development.md#local-terraform-runs) need a separately created key.
Enrollment keys can enter state and cloud-init data.

## 3. Configure the operators and private Argo CD access

1. Enable MagicDNS and HTTPS certificates in the Tailscale admin console.
2. Add these entries to the tailnet policy alongside the node and CI rules.
   Replace `you@example.com` with the administrator account. Existing broad
   grants still apply.

   ```json
   {
     "tagOwners": {
       "tag:kurza-k8s-operator": ["autogroup:admin"],
       "tag:kurza-k8s-proxy": ["tag:kurza-k8s-operator"],
       "tag:kurza-argocd": ["tag:kurza-k8s-operator"]
     },
     "autoApprovers": {
       "services": {
         "tag:kurza-argocd": ["tag:kurza-k8s-proxy"]
       }
     },
     "grants": [
       {
         "src": ["you@example.com"],
         "dst": ["svc:argocd", "tag:kurza-k8s-proxy"],
         "ip": ["tcp:443"]
       }
     ]
   }
   ```

   The proxy-device grant works around missing Service-host routes in
   [Tailscale issue #19666](https://github.com/tailscale/tailscale/issues/19666).
   Use a dedicated proxy tag if future proxies need different access.

3. Create a **separate OAuth client** tagged `tag:kurza-k8s-operator` with write
   permissions for **General / Services**, **Devices / Core**, and
   **Keys / Auth Keys**. The in-cluster operator uses this client independently
   of the GitHub and node-enrollment identities.
4. Store the OAuth **client ID and client secret** as two secrets in Bitwarden
   Secrets Manager. Set GitHub Actions variable `BWS_OPERATOR_SECRET_IDS` to
   their UUIDs (not their values):

   ```json
   {"client_id": "CLIENT_ID_SECRET_UUID", "client_secret": "CLIENT_SECRET_SECRET_UUID"}
   ```

5. Create a dedicated Bitwarden machine account with read access to that project.
   Store its access token in GitHub Actions secret `BWS_OPERATOR_ACCESS_TOKEN`.
   This is separate from the existing cluster provisioning `BWS_ACCESS_TOKEN`.
   Bootstrap also uses `BWS_ORGANIZATION_ID` and the existing optional
   `BWS_API_URL` / `BWS_IDENTITY_API_URL` settings, including EU endpoints.

## 4. Configure GitHub Actions

In Settings > Secrets and variables > Actions, configure:

| Type | Name | Value |
| --- | --- | --- |
| Variable | `TF_STATE_BUCKET` | Existing state bucket name |
| Variable | `AWS_REGION` | Bucket's AWS region |
| Variable | `AWS_IAM_ROLE` | AWS role ARN assumed through GitHub OIDC |
| Secret | `BWS_ACCESS_TOKEN` | Bitwarden machine-account access token |
| Variable | `BWS_ORGANIZATION_ID` | Bitwarden organization UUID |
| Variable | `BWS_IDENTITY_PROJECT_ID` | Existing Bitwarden project UUID for automatically generated Pocket ID and Argo CD secrets |
| Variable | `BWS_SECRET_IDS` | JSON object shown below, containing secret UUIDs |
| Variable | `TS_MAGICDNS_DOMAIN` | Tailnet domain, for example `example-tailnet.ts.net` |
| Variable | `TS_CLIENT_ID` | Tailscale federated identity client ID for the cluster workflow |
| Variable | `TS_AUDIENCE` | Audience configured on that Tailscale federated identity |
| Variable | `TS_NODE_CLIENT_ID` | Separate federated identity client ID restricted to `tag:kurza-cluster` |
| Variable | `TS_NODE_AUDIENCE` | Audience configured on the node enrollment federated identity |
| Variable | `BWS_OPERATOR_SECRET_IDS` | JSON object with `client_id` and `client_secret` Bitwarden UUIDs |
| Secret | `BWS_OPERATOR_ACCESS_TOKEN` | Dedicated Bitwarden machine token for in-cluster secret synchronization |
| Variable | `BWS_OPERATOR_ACCESS_TOKEN_REVISION` | Positive integer; increment when rotating the BWS operator token (default `1`) |
| Variable | `BWS_API_URL` | Optional; defaults to `https://api.bitwarden.com` |
| Variable | `BWS_IDENTITY_API_URL` | Optional; defaults to `https://identity.bitwarden.com` |

```json
{
  "hcloud_token": "YOUR_HETZNER_TOKEN_SECRET_UUID",
  "ssh_public_key": "YOUR_PUBLIC_KEY_SECRET_UUID",
  "ssh_private_key": "YOUR_PRIVATE_KEY_SECRET_UUID"
}
```

For Bitwarden EU, set the two endpoint variables to `https://api.bitwarden.eu`
and `https://identity.bitwarden.eu`, respectively.

Repository settings use `BWS_` names; CI maps them to the provider's `BW_`
environment variables. Give `BWS_ACCESS_TOKEN` read/write access to the identity
project and `BWS_OPERATOR_ACCESS_TOKEN` read access. Bootstrap uses the separate,
write-only operator token for in-cluster synchronization.
Cluster credentials and the admin kubeconfig enter state and saved plans;
access is covered under [security and credential rotation](security.md).

## 5. Build the Hetzner base images

Manually run **Hetzner Cloud Initialization** in GitHub Actions and select **x86**
for the default `cx23` node. Select ARM for `cax` types. The workflow retrieves
the Hetzner token from Bitwarden using the repository settings above.

For a local build, install Packer **1.16.0**, export `HCLOUD_TOKEN`, then run:

```sh
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-x86-snapshot
```

Builds create billable temporary servers and snapshots. Inspect the Hetzner
project after a failed build. Deployments do not build images, and rebuilding
an image does not replace existing nodes. ARM builds, capacity overrides and
bundle maintenance are in the [image-build reference](../terraform/cluster/hcloud-init/README.md).

## 6. Deploy

In Actions, choose **Terraform Apply > Run workflow** on the default branch to
plan and apply cluster, then bootstrap, then identity. All jobs join the tailnet. Bootstrap
creates its Bitwarden auth Secret through Terraform's write-only `data_wo`
argument before installing the credential mapping and Tailscale operator.
After deployment: [cluster checks and Argo CD login](access.md).
Public applications also require [Cloudflare ingress configuration](operations.md#application-ingress).
Complete [Pocket ID administrator enrollment](pocket-id.md#enroll-your-administrator)
on first deployment. Credentials and the Argo CD client are provisioned automatically.

Pull requests matching the workflow path filters validate all three layers without
cloud credentials. Validation downloads modules, providers and the Argo CD chart.
Pushes do not deploy. Manual runs on other branches only validate. Deployments
are serialized and active applies are not cancelled. Snapshot builds use a
separate concurrency lock. Deployment creates billable Hetzner resources.
