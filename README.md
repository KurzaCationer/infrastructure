# Infrastructure

This repository provisions a private, single-node k3s cluster on Hetzner Cloud
and bootstraps Argo CD. Terraform manages infrastructure and platform services,
GitHub Actions deploys them, Tailscale provides private access, and Bitwarden
Secrets Manager supplies credentials.

**Start with [Setup](#setup)** for the full first-deployment sequence. This is the
central setup and operations guide; directory READMEs provide local reference
and specialist maintenance details.

- [Architecture and repository map](#architecture-and-repository-map)
- [Setup](#setup)
- [Verify and access the deployment](#verify-and-access-the-deployment)
- [Operations and destruction](#operations-and-destruction)
- [Local Terraform runs](#local-terraform-runs)
- [Validation](#validation)
- [Security and ownership](#security-and-ownership)

## Architecture and repository map

The layers run in order: **cluster -> bootstrap**. Both use the existing S3 bucket
with separate state keys and native S3 locking. CI uses Terraform 1.16.6.

- `cluster`: Kube-Hetzner 3.2.1 with one schedulable `cx23` control-plane node in
  `nbg1`, running k3s and workloads together. No worker nodes. Automatic upgrades
  are disabled. Cilium supplies the CNI, kube-proxy replacement, and Gateway API
  controller; Traefik is disabled. The Cilium operator runs one replica.
- `bootstrap`: installs the Bitwarden and Tailscale Kubernetes operators and
  Argo CD, published privately as Tailscale Service `svc:argocd`.

This is a small, non-HA starting point. Nodes enroll into Tailscale during
cloud-init. Public SSH and Kubernetes API firewall rules are disabled;
Terraform and operators connect using the node's tailnet MagicDNS name.
Nodes retain public addresses for outbound bootstrap and Tailscale connectivity.

The Terraform `bootstrap` layer reads the cluster kubeconfig from S3 and installs
Bitwarden Secrets Manager operator chart **2.0.3**, a `BitwardenSecret` mapping,
Tailscale operator **1.104.1**, then Argo CD chart **10.10.5**. Argo CD deploys
ExternalDNS, wildcard certificates, a shared public Gateway and the test
application at `test.kurza.nl` from `argocd/`. cert-manager is already installed
by Kube-Hetzner (enabled by default).
Terraform owns the bootstrap releases, including the ProxyGroup and ingress in
[`terraform/bootstrap/values/argocd.yaml`](terraform/bootstrap/values/argocd.yaml).
Bootstrap seeds only the root `infrastructure` Argo CD Application, which watches
`argocd/` and creates its child Applications. It supplies the non-secret
Bitwarden organization UUID and public origin IP. Existing operators stay under
their current owners; Argo CD manages the new public application resources.
Bootstrap Helm values belong in `terraform/bootstrap/values/`.

Argo CD is available at `https://argocd.<your-tailnet>.ts.net` as Tailscale Service
`svc:argocd`. Its Kubernetes Service stays `ClusterIP`. Only the Tailscale ingress
controller handles its ingress; no Cilium Gateway, NodePort, external load
balancer, or Funnel is configured. HTTPS terminates on the Tailscale proxy and
uses HTTP to the internal Argo CD service. Argo CD authentication remains enabled.
The one-replica ProxyGroup matches this single-node cluster; it provides no HA.
Its ProxyClass disables UDP segmentation offload to avoid stalled large downloads
on the deployed Cilium network path.

| Path | Responsibility |
| --- | --- |
| [`terraform/cluster/`](terraform/cluster/) | Hetzner cluster, networking, firewall, Cilium and private node transport; state key `cluster/terraform.tfstate` |
| [`terraform/cluster/hcloud-init/`](terraform/cluster/hcloud-init/) | Separate Packer snapshot builds and vendored security bundle |
| [`terraform/bootstrap/`](terraform/bootstrap/) | Bitwarden and Tailscale operators, OAuth secret mapping and Argo CD; state key `bootstrap/terraform.tfstate` |
| [`terraform/bootstrap/values/argocd.yaml`](terraform/bootstrap/values/argocd.yaml) | Terraform-owned Argo CD settings, ingress ProxyGroup and private Ingress |
| `argocd/` | Argo CD Application, AppProject, public platform chart and controller values |
| [`scripts/`](scripts/) | Local cluster checks and admin kubeconfig retrieval for Bash and Windows |
| [`.github/workflows/`](.github/workflows/) | Validation, manual image builds, apply and destroy workflows |
| [`.github/scripts/`](.github/scripts/) | Enrollment-key lifecycle, Argo CD manifest checks and helper tests |

## Setup

Complete these steps in order. The state bucket, credentials, tailnet and matching
base-image snapshots must exist before the first Terraform apply. All commands
in this guide run from the repository root unless stated otherwise.

### 1. Prepare accounts, tools and AWS state

You need a Hetzner project, an AWS account, a Bitwarden Secrets Manager organization,
a Tailscale tailnet and permission to configure GitHub Actions in this repository.

CI installs Terraform **1.16.6** and Packer **1.16.0**. Local verification requires
Terraform **>= 1.16.6, < 2.0**, Tailscale, kubectl and AWS authentication. Install
and authenticate `gh` to read GitHub settings automatically, or set the backend
environment variables yourself. The first-login commands also use the Argo CD CLI.
Local image builds require
Linux/WSL/macOS with Bash, Packer 1.16.0, `curl`, `unzip` and `sha256sum`
(GNU coreutils on macOS).

1. Create an S3 state bucket with versioning, encryption, and public access blocked.
2. Configure GitHub OIDC trust for the default branch on the existing role:
   `arn:aws:iam::154009488279:role/kurza-infrastructure-github-actions-role`.
   Trust audience `sts.amazonaws.com` and the repository's actual OIDC subject.
3. Give the role `s3:ListBucket` on the bucket for `cluster/*` and `bootstrap/*`,
   `s3:GetObject`/`s3:PutObject` on each layer's `terraform.tfstate` object, and
   `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on each lock object, for example
   `cluster/terraform.tfstate.tflock` and `bootstrap/terraform.tfstate.tflock`.
   A customer-managed KMS key also needs appropriate key permissions.
4. Store a Hetzner project Read & Write API token, SSH public key, and matching
   unencrypted SSH private key in Bitwarden Secrets Manager.
   Give a machine account read access to these secrets and create an access token.

The bucket and role are existing prerequisites, not resources created here.
The reusable workflow restricts AWS authentication to account `154009488279`.
To use another account, update `allowed-account-ids` in
[`.github/workflows/terraform-layer.yml`](.github/workflows/terraform-layer.yml)
as well as the role setting. Use your actual default-branch OIDC subject, such
as `repo:OWNER/REPOSITORY:ref:refs/heads/DEFAULT_BRANCH`.

### 2. Configure private node access

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

SSH uses the deployment SSH private key over Tailscale. Tailscale SSH is not enabled,
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

### 3. Configure the operators and private Argo CD access

Bootstrap reads the cluster kubeconfig from S3 and installs the Bitwarden operator,
the BitwardenSecret mapping, the Tailscale operator, then Argo CD. Terraform owns
all of these releases and their ingress resources.

1. Enable MagicDNS and HTTPS certificates in the Tailscale admin console.
2. Merge the following entries into your existing tailnet policy (preserve the
   node and CI rules). Replace `you@example.com` with the authorized administrator.
   Review existing broad allow rules too: grants are additive.

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

   The proxy-device destination is a workaround for
   [Tailscale Service route publication issue #19666](https://github.com/tailscale/tailscale/issues/19666).
   In this deployment, granting access only to the Service made it discoverable
   but left its host absent from the client's route map. Allowing the same user
   TCP 443 to the ingress proxy restored connectivity. The tag covers proxy
   devices; use a dedicated proxy tag if future proxies need different access.

3. Create a **separate OAuth client** tagged `tag:kurza-k8s-operator` with write
   permissions for **General / Services**, **Devices / Core**, and
   **Keys / Auth Keys**. This runs continuously inside Kubernetes; the existing
   GitHub and node-enrollment federated identities are not its credentials.
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
6. Record `TS_MAGICDNS_DOMAIN`, `TS_CLIENT_ID`, and `TS_AUDIENCE` from step 2
   for GitHub configuration below. Preserve the CI device's TCP 6443 grant to
   `tag:kurza-cluster`.

### 4. Configure GitHub Actions

In Settings > Secrets and variables > Actions, configure:

| Type | Name | Value |
| --- | --- | --- |
| Variable | `TF_STATE_BUCKET` | Existing state bucket name |
| Variable | `AWS_REGION` | Bucket's AWS region |
| Variable | `AWS_IAM_ROLE` | AWS role ARN assumed through GitHub OIDC |
| Secret | `BWS_ACCESS_TOKEN` | Bitwarden machine-account access token |
| Variable | `BWS_ORGANIZATION_ID` | Bitwarden organization UUID |
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

The workflow exposes the existing `BWS_ACCESS_TOKEN` secret as `BW_ACCESS_TOKEN`,
which is the Terraform provider's environment variable. The cluster deployment
maps `BWS_ORGANIZATION_ID`, `BWS_API_URL`, and `BWS_IDENTITY_API_URL` to the
provider-required `BW_ORGANIZATION_ID`, `BW_API_URL`, and `BW_IDENTITY_API_URL`.
These `BW_` names are internal provider settings; repository settings use `BWS_`.
The cluster deployment fetches secret values directly through Terraform. Only the separate Packer
workflow uses the Bitwarden GitHub Action. Bootstrap receives the separate
`BWS_OPERATOR_ACCESS_TOKEN` as an ephemeral Terraform input written to a Kubernetes
Secret using the provider's write-only `data_wo` argument.
The Bitwarden Kubernetes operator syncs the Tailscale credentials from Bitwarden;
their values never pass through Terraform or Helm. See Security and ownership below.

Bitwarden data-source values and the admin kubeconfig are stored in Terraform
state and saved plans. Restrict state access accordingly; marking a value sensitive
only hides it in ordinary output. Plans are applied within the job and are not
uploaded as artifacts.

### 5. Build the Hetzner base images

For the snapshots, install Packer **1.16.0**, export `HCLOUD_TOKEN`, and run:

```sh
bash terraform/cluster/hcloud-init/build.sh
```

Alternatively, manually run **Hetzner Cloud Initialization** in GitHub Actions and select x86,
ARM, or both. It retrieves the Hetzner token using the Bitwarden GitHub Action
and the existing repository settings. It is never triggered automatically.

The image builds create temporary servers and billable snapshots in Hetzner.
They are a separate, deliberate initialization step; GitHub deployment runs do
not rebuild images automatically. No Terraform module download is needed first.

The default cluster needs an x86 snapshot; `cax` server types need ARM. The local
wrapper builds both architectures unless you select one:

```sh
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-x86-snapshot
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-arm-snapshot
```

Default build servers are `cx23` in `nbg1` (x86) and `cax11` in `fsn1` (ARM).
Override build capacity or location when needed:

```sh
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-x86-snapshot -var=x86_server_type=cpx31 -var=x86_location=fsn1
```

The wrapper verifies the vendored bundle, installs the hash-verified hcloud Packer
plugin, validates the Leap Micro template and builds k3s snapshots. The legacy
MicroOS template remains for bundle integrity but is not built by the wrapper.
Successful builds remove temporary servers; inspect the Hetzner project after a
failed build. Rebuilding snapshots does not update or replace existing nodes.

### 6. Deploy

In Actions, choose **Terraform Apply > Run workflow** on the default branch to
plan and apply cluster, then bootstrap. Both jobs join the tailnet. Bootstrap
creates its Bitwarden auth Secret through Terraform's write-only `data_wo`
argument before installing the credential mapping and Tailscale operator.
Continue with verification and first login below.

Pull requests matching the workflow path filters validate both layers without
cloud credentials. Validation downloads modules, providers and the Argo CD chart.
Pushes do not deploy. Manual runs on other branches only validate. Deployments
are serialized and active applies are not cancelled. Snapshot builds use a
separate concurrency lock. Deployment creates billable Hetzner resources.

## Verify and access the deployment

After GitHub applies, update your checkout to the deployed commit. Have Terraform
**>= 1.16.6, < 2.0**, Tailscale, and kubectl installed, with AWS credentials already
available and your workstation already connected to the tailnet. The scripts do
not log into AWS or Tailscale and do not require Bitwarden credentials or a node
enrollment key.

From the repository root, run:

```sh
# Linux / Bash
bash scripts/check-cluster.sh
```

```powershell
# Windows PowerShell; in CMD omit the leading .\
.\scripts\check-cluster.bat
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
| `KUBECONFIG_PATH` | Your home directory's `.kube/kurza-infrastructure.yaml` |
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
3. Save the admin kubeconfig as `~/.kube/kurza-infrastructure.yaml` on Linux or
   `%USERPROFILE%\.kube\kurza-infrastructure.yaml` on Windows. Failed output retrieval preserves
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

### Verify bootstrap and sign in

After loading the kubeconfig using `scripts/check-cluster.sh` or
`scripts\check-cluster.bat`, select it and inspect the deployment:

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

The ingress ADDRESS should become `argocd.<your-tailnet>.ts.net`; services should
remain `ClusterIP`. From an authorized tailnet device, open that HTTPS URL and log
in as `admin`. Retrieve the generated password locally:

```sh
argocd admin initial-password -n argocd
argocd login argocd.<your-tailnet>.ts.net --grpc-web
argocd account update-password --grpc-web
kubectl -n argocd delete secret argocd-initial-admin-secret
```

Keep the password out of CI logs. The CLI uses `--grpc-web` through the HTTPS
proxy. After changing the password, remove the initial password Secret as shown.
Dex is disabled until an SSO provider is configured.

Confirm the HTTPS endpoint works while connected to an allowed tailnet identity
and is unreachable from a device outside the tailnet. Check the admin console's
Services page for `svc:argocd` and its approved host, and inspect operator logs
if the ingress ADDRESS stays empty. A successful Helm apply alone does not prove
that tailnet approval, DNS, certificates, or grants are correct.

## Operations and destruction

Rerun **Terraform Apply** on the default branch to deploy configuration changes.
Automatic OS and Kubernetes upgrades are disabled. Refresh snapshots deliberately
and plan node replacement separately; this single-node cluster has no redundancy
during replacement or maintenance.

Argo CD automatically reconciles the public platform from the repository default
branch. Terraform retains ownership of its existing bootstrap releases.

### Application ingress

The Terraform-seeded root Application loads the child Applications under
`argocd/`. They configure the existing cert-manager with Let's Encrypt DNS-01
for `*.dylannas.nl` and `*.kurza.nl`, install ExternalDNS, and deploy
`test.kurza.nl`. Cloudflare proxies traffic to Cilium on the existing node IP;
public ports 80/443 accept only Cloudflare's published IPv4/IPv6 ranges.

Setup:

1. Give the Cloudflare token **Zone / DNS / Edit** and **Zone / Zone / Read** for
   only these two zones. Its Bitwarden UUID is in
   `argocd/platform/ingress/cloudflare-credentials.yaml`. Grant the existing BWS
   operator machine account read access. Set both Cloudflare zones to **Full
   (strict)** with Universal SSL enabled; resolve any existing `test.kurza.nl`
   DNS conflict and ensure CAA records, if present, permit `letsencrypt.org`.
2. Merge and run **Terraform Apply** once to configure the firewall/Cilium and
   root Application. Argo CD then reconciles `argocd/` automatically. If the
   repository is private, first configure its read-only credentials in Argo CD.
3. Terraform writes the same BWS operator token into `tailscale`, `cert-manager`
   and `external-dns` before Argo CD starts its applications. The existing
   operator-token revision controls rotation in all three namespaces. No extra
   pipeline steps or Secret copying are required.

Verify `kubectl -n argocd get applications`, wait for both certificates to be
Ready in `public-ingress`, then open `https://test.kurza.nl`. Direct access must
fail from outside the tailnet, even with the correct hostname:

```sh
ORIGIN_IP=$(terraform -chdir=terraform/cluster output -raw public_ingress_ipv4)
curl --connect-timeout 5 --max-time 10 --resolve "test.kurza.nl:443:$ORIGIN_IP" https://test.kurza.nl
```

The ACME email is `mail@kurza.nl`; TLS/ACME keys stay in Kubernetes. The browser
shows Cloudflare's edge certificate; Full (strict) validates the Let's Encrypt
origin certificate. Add future apps using the test manifests as an example,
reusing the shared Gateway and its namespace/route opt-in labels. Removing the
`https-test` Application from `argocd/kustomization.yaml` removes the example.
ExternalDNS retains DNS records on removal (`upsert-only`); remove retired names
and their ownership TXT records manually. Review Cloudflare IP ranges in
`terraform/cluster/cloudflare.tf` when [Cloudflare updates them](https://www.cloudflare.com/ips/).

### Destroy

To tear down the infrastructure, choose **Terraform Destroy > Run workflow** on
the default branch and enter `destroy` in the confirmation input. This workflow
only runs manually. It destroys **bootstrap -> cluster**, stopping if either
layer fails, and shares the deployment concurrency lock so deploy and destroy
cannot overlap. Each layer creates a saved destroy plan and applies that plan
using the same backend, credentials, and private network access as deployment.
The cluster job also reuses the short-lived enrollment-key creation and revocation
lifecycle, so the same node federation settings are required.

Destruction removes resources managed by these Terraform states. The existing S3
state bucket and separately built Hetzner snapshots remain.

## Local Terraform runs

### Cluster

For local plans/applies, connect to the tailnet, authenticate to AWS and export
`TF_VAR_tailscale_magicdns_domain` and a fresh `TF_VAR_tailscale_auth_key` for
durable nodes tagged `tag:kurza-cluster`. Revoke the enrollment key afterward,
including on failure. The federation helper needs the GitHub Actions OIDC
environment and is intended to run inside CI.

Export `BW_ACCESS_TOKEN`,
`BW_ORGANIZATION_ID`, `BW_API_URL`, and `BW_IDENTITY_API_URL`, and put the secret-ID
object in `TF_VAR_bitwarden_secret_ids` or a gitignored `terraform.tfvars` file.
Optional Terraform variables `cluster_name`, `location`, and `server_type` default
to `kurza`, `nbg1`, and `cx23`. Location must stay in `eu-central`. Set `server_type`
to a `cax` type (for example, `cax11`) for ARM; other types select x86. Build the
matching snapshot first. Changing architecture replaces the node; this single-node
setup has no redundancy during replacement or maintenance.

```sh
terraform -chdir=terraform/cluster init -reconfigure -backend-config="bucket=YOUR_BUCKET" -backend-config="region=YOUR_REGION"
terraform -chdir=terraform/cluster plan -out=deployment.tfplan
terraform -chdir=terraform/cluster apply deployment.tfplan
```

The module does not write kubeconfig or kustomization files during CI runs.

Commit the provider lock file. State, local variable files, plans, and
`.terraform/` directories are ignored.

### Bootstrap

After the cluster has been applied, initialize the bootstrap backend separately:

```sh
terraform -chdir=terraform/bootstrap init -reconfigure -backend-config="bucket=YOUR_BUCKET" -backend-config="region=YOUR_REGION"
```

Stay connected to the tailnet and provide
`TF_VAR_state_bucket`, `TF_VAR_aws_region`, `TF_VAR_tailscale_magicdns_domain`,
`TF_VAR_bitwarden_organization_id`, and `TF_VAR_tailscale_operator_secret_ids`.
Set `TF_VAR_bitwarden_api_url` / `TF_VAR_bitwarden_identity_url` for EU or self-hosted
Bitwarden. AWS credentials must also be able to read `cluster/terraform.tfstate`.
Supply the BWS operator token securely through
`TF_VAR_bitwarden_operator_access_token`. This variable is sensitive and ephemeral;
keep it available for both planning and applying a saved plan, including destroy
runs. Set `TF_VAR_bitwarden_operator_access_token_revision` to a positive integer
(default `1`) and increment it when rotating the token.

Create and review a saved plan and apply it:

```sh
terraform -chdir=terraform/bootstrap plan -out=deployment.tfplan
terraform -chdir=terraform/bootstrap apply deployment.tfplan
```

Bootstrap's variables default to US Bitwarden endpoints; override them for
EU/self-hosted deployments. Keep the token in your environment, outside committed
configuration files.

## Validation

These checks need no cloud credentials:

```sh
terraform fmt -check -recursive terraform
terraform -chdir=terraform/cluster init -backend=false
terraform -chdir=terraform/cluster validate
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap validate
```

CI also runs these helper tests with mocked commands/network responses:

```sh
python3 .github/scripts/test_tailscale_enrollment.py
```

To reproduce the Argo CD private-exposure check, install Helm and Python package
`PyYAML==6.0.3`, then run:

```sh
python3 .github/scripts/check_argocd.py
python3 .github/scripts/check_public_ingress.py
```

The check renders the pinned chart and rejects public Services, host ports and
unexpected ingress routes. It downloads the chart but needs no cluster credentials.
Terraform initialization also downloads modules/providers. For an image-bundle
integrity check, use Bash with `sha256sum`:

```sh
cd terraform/cluster/hcloud-init
sha256sum --check security-bundle.sha256
```

## Security and ownership

Terraform manages `tailscale/bitwarden-auth` using `kubernetes_secret_v1.data_wo`.
The same write-only input initializes `bitwarden-auth` in `cert-manager` and
`external-dns`. All three Secrets use the same rotation revision; token values
stay out of saved plans, state and Helm values.
Its token comes from a sensitive, ephemeral input and is omitted from saved plans
and state. This initial machine token lets the Bitwarden operator log in and
bootstrap secret synchronization. It is never supplied to Helm.

The Bitwarden operator then fetches the two Tailscale credentials directly from
Bitwarden and creates `tailscale/operator-oauth` with keys `client_id` and
`client_secret`. Only the mapped secrets are synchronized. The Tailscale chart
mounts this existing Secret; Terraform and Helm receive only UUIDs and Secret
names for the Tailscale credentials. Neither credential values nor the Bitwarden access token enter Terraform
plans/state or Helm values/release data with this configuration. Both Secrets
exist in Kubernetes, so protect cluster admin access and backups.

To rotate Tailscale
credentials, update Bitwarden, wait for synchronization, and restart the consumer
with `kubectl -n tailscale rollout restart deployment/operator`. To rotate the
Bitwarden token, update `BWS_OPERATOR_ACCESS_TOKEN`, increment
`BWS_OPERATOR_ACCESS_TOKEN_REVISION`, and rerun the apply workflow. Terraform cannot detect
changes to a write-only value without that revision change.

The namespace and auth Secret are Terraform resources and are removed after the
dependent releases during bootstrap destroy. If the previous script already created
them, import the namespace and remove the old auth Secret immediately before
applying, so Terraform recreates the token through the write-only field:

```sh
terraform -chdir=terraform/bootstrap import kubernetes_namespace_v1.tailscale tailscale
kubectl -n tailscale delete secret bitwarden-auth
terraform -chdir=terraform/bootstrap apply
```

The Bitwarden operator cannot refresh secrets between deletion and recreation.
Avoid importing the old auth Secret: an ordinary import can read its payload into
state before write-only configuration is applied. If this replaces an already-applied version that passed
credentials to Helm/Terraform, rotate those credentials and handle historical S3
state versions separately; changing the configuration cannot erase old snapshots.

The Service advertisement auto-approver is required for unattended publication.
Without it, approve the advertised Service hosts manually in the Tailscale admin
console. Reserve the name `argocd` for this installation in your tailnet.

Cluster secret values, the admin kubeconfig and potentially the node enrollment
key enter Terraform state and saved plans. Enrollment keys also reach Hetzner
cloud-init user data. Sensitive output flags do not remove these values from
state. Restrict state/project access and protect admin kubeconfigs and backups.
Plans are applied in the CI job without uploading plan artifacts.

For signing-key rotation, see the
[trust-anchor maintenance notes](terraform/cluster/hcloud-init/keys/README.md).
Keep the reviewed Packer bundle aligned with the pinned Kube-Hetzner module;
rotate keys and hashes together instead of bypassing verification.

Configuration references: [cluster inputs](terraform/cluster/variables.tf),
[bootstrap inputs](terraform/bootstrap/variables.tf),
[deployment workflow](.github/workflows/terraform-layer.yml).
