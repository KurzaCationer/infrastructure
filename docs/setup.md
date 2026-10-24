# Setup

Configure AWS, Hetzner Cloud, Bitwarden Secrets Manager, Tailscale and GitHub
Actions before deploying. Public endpoints also require the
[Cloudflare settings](operations.md#application-ingress).

## AWS state

The S3 bucket and IAM role are managed outside this repository.

- Enable bucket versioning and encryption; block public access.
- Allow GitHub OIDC audience `sts.amazonaws.com` and subject
  `repo:OWNER/REPOSITORY:ref:refs/heads/DEFAULT_BRANCH`.
- Grant `s3:ListBucket` for `cluster/*`, `bootstrap/*` and `identity/*`;
  `s3:GetObject`/`s3:PutObject` for each `terraform.tfstate`;
  and `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` for each
  `terraform.tfstate.tflock`.
- Grant KMS access if the bucket uses a customer-managed key.

The workflow restricts AWS authentication to account `154009488279`.
Changing accounts also requires updating `allowed-account-ids` in
[terraform-layer.yml](../.github/workflows/terraform-layer.yml).

## Tailscale

Enable MagicDNS and HTTPS certificates. Reserve the Service name `argocd`.

| Identity | Permissions | Tag |
| --- | --- | --- |
| GitHub runner federation | Writable `auth_keys` | `tag:ci` |
| Node enrollment federation | Writable `auth_keys` | `tag:kurza-cluster` |
| Kubernetes operator OAuth client | Write: General / Services, Devices / Core, Keys / Auth Keys | `tag:kurza-k8s-operator` |

Restrict both federated identities to this repository's default branch.
Record each client ID and configured audience in GitHub.

Define tag owners for `tag:ci` and `tag:kurza-cluster`. Permit administrators
and `tag:ci` to reach cluster nodes on TCP 22 and 6443.

Merge the following into the tailnet policy, replacing the administrator address.
Existing grants still apply.

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

Use a dedicated proxy tag if additional proxies need different access.

## Bitwarden

Store the Hetzner Read & Write API token, SSH public key and matching unencrypted
private key in Secrets Manager. Store the Tailscale operator OAuth client ID and
secret as separate records. Create an identity project for generated secrets.

| Machine account token | Required access |
| --- | --- |
| `BWS_ACCESS_TOKEN` | Read cluster credentials; read/write identity project |
| `BWS_OPERATOR_ACCESS_TOKEN` | Read operator OAuth credentials, Cloudflare token and identity project |

## GitHub Actions settings

Configure repository Actions secrets and variables:

| Type | Name | Value |
| --- | --- | --- |
| Variable | `TF_STATE_BUCKET` | Existing S3 bucket |
| Variable | `AWS_REGION` | Bucket region |
| Variable | `AWS_IAM_ROLE` | GitHub OIDC role ARN |
| Secret | `INFRASTRUCTURE_VARIABLE_TOKEN` | Fine-grained PAT limited to this repository, with Variables read/write |
| Variable | `HCLOUD_INITIALIZED` | Workflow-managed; absent or `false` until initialization succeeds |
| Secret | `BWS_ACCESS_TOKEN` | Provisioning machine-account token |
| Secret | `BWS_OPERATOR_ACCESS_TOKEN` | Operator machine-account token |
| Variable | `BWS_ORGANIZATION_ID` | Organization UUID |
| Variable | `BWS_IDENTITY_PROJECT_ID` | Identity project UUID |
| Variable | `BWS_SECRET_IDS` | Cluster credential UUIDs; JSON below |
| Variable | `BWS_OPERATOR_SECRET_IDS` | OAuth credential UUIDs; JSON below |
| Variable | `BWS_OPERATOR_ACCESS_TOKEN_REVISION` | Positive integer; increment on rotation; default `1` |
| Variable | `TS_MAGICDNS_DOMAIN` | Tailnet domain, e.g. `example-tailnet.ts.net` |
| Variable | `TS_CLIENT_ID` | Runner federation client ID |
| Variable | `TS_AUDIENCE` | Runner federation audience |
| Variable | `TS_NODE_CLIENT_ID` | Node federation client ID |
| Variable | `TS_NODE_AUDIENCE` | Node federation audience |
| Variable | `BWS_API_URL` | Optional; default `https://api.bitwarden.com` |
| Variable | `BWS_IDENTITY_API_URL` | Optional; default `https://identity.bitwarden.com` |

Create `INFRASTRUCTURE_VARIABLE_TOKEN` once using a fine-grained personal access
token with repository **Variables: read and write** permission. The built-in
`GITHUB_TOKEN` cannot be granted that permission. Keep the token valid (rotate it
before expiration); initialization checks variable write access before building.
The workflows create and update `HCLOUD_INITIALIZED` automatically. Do not set it
to `true` manually to bypass initialization.

`BWS_SECRET_IDS`:

```json
{
  "hcloud_token": "HETZNER_TOKEN_SECRET_UUID",
  "ssh_public_key": "PUBLIC_KEY_SECRET_UUID",
  "ssh_private_key": "PRIVATE_KEY_SECRET_UUID"
}
```

`BWS_OPERATOR_SECRET_IDS`:

```json
{
  "client_id": "CLIENT_ID_SECRET_UUID",
  "client_secret": "CLIENT_SECRET_SECRET_UUID"
}
```

For Bitwarden EU, use `https://api.bitwarden.eu` and
`https://identity.bitwarden.eu`.

## Deployment

Build a matching snapshot with **Hetzner Cloud Initialization** before the first
apply. Select ARM for the current `cax21` default; non-`cax` types use x86.
See [image builds](../terraform/cluster/hcloud-init/README.md).

Successful initialization sets `HCLOUD_INITIALIZED=true` and automatically
triggers **Terraform Apply** on the default branch. Pushes and merges to `main`
also deploy while this variable is `true`; manual applies use the same gate.
Pull requests only validate and do not receive the lifecycle token.
Configure Argo CD repository read credentials if a Git source is private.

Initialization, deployment and teardown share the `terraform-deploy` concurrency
group. Each deployment reads the variable live after acquiring that lock, and
each Terraform layer rechecks it, including when retrying failed jobs. Missing,
`false` or `destroying` values block deployment; API errors fail closed.
GitHub retains only one pending run per concurrency group, so newer requests can
replace pending ones; an active run is never cancelled by a new request.

Complete [Pocket ID administrator enrollment](pocket-id.md#administrator-enrollment)
immediately after first deployment, then verify [cluster and Argo CD access](access.md).
