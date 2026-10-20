# Security and credentials

[Home](../README.md) · [Setup](setup.md) · [Access](access.md) · [Architecture](architecture.md) · [Operations](operations.md) · [Development](development.md) · [Security](security.md)

Commands assume the repository root and the [cluster kubeconfig](access.md#verify-bootstrap-and-sign-in).

## Secret handling

Terraform writes the Bitwarden machine token to `bitwarden-auth` Secrets in
`tailscale`, `cert-manager` and `external-dns` using `kubernetes_secret_v1.data_wo`.
The input is sensitive and ephemeral; the token stays out of saved plans, state
and Helm values. All three Secrets share a rotation revision.

The Bitwarden operator reads the mapped Tailscale credentials and creates
`tailscale/operator-oauth` with `client_id` and `client_secret`. The Tailscale
chart mounts this Secret. Terraform and Helm receive UUIDs and Secret names
only; the credential values stay in Bitwarden and Kubernetes. Cluster admin
access and backups therefore include access to these credentials.

## Credential rotation

- **Tailscale OAuth:** update Bitwarden, wait for synchronization, then run
  `kubectl -n tailscale rollout restart deployment/operator`.
- **Bitwarden machine token:** update `BWS_OPERATOR_ACCESS_TOKEN`, increment
  `BWS_OPERATOR_ACCESS_TOKEN_REVISION` and rerun **Terraform Apply**. The revision
  change triggers the write-only Secret update.

## Migrating an existing auth Secret

For installations where the namespace and auth Secret were created by the old
script, import the namespace and delete the Secret immediately before applying.
Terraform recreates the Secret through the write-only field:

```sh
terraform -chdir=terraform/bootstrap import kubernetes_namespace_v1.tailscale tailscale
kubectl -n tailscale delete secret bitwarden-auth
terraform -chdir=terraform/bootstrap apply
```

Secret synchronization pauses between deletion and recreation. Importing the old
auth Secret can copy its payload into state before the write-only configuration
is applied.

Credentials previously passed through Helm or Terraform need rotation. Historical
S3 state versions retain those values after the configuration changes.

## Access and state protection

The tailnet reserves `argocd` for this installation. The Service auto-approver
allows unattended publication; without it, advertised hosts need manual approval
in the Tailscale admin console.

Cluster secret values, the admin kubeconfig and potentially the node enrollment
key enter Terraform state and saved plans. Enrollment keys also reach Hetzner
cloud-init user data. The `sensitive` flag hides output but leaves values in
state. State, Hetzner project access, admin kubeconfigs and backups all require
restricted access.
Plans are applied in the CI job without uploading plan artifacts.

Packer signing-key rotation is documented in the
[trust-anchor notes](../terraform/cluster/hcloud-init/keys/README.md). The bundle,
keys and hashes are versioned together with the pinned Kube-Hetzner module.

Configuration references: [cluster inputs](../terraform/cluster/variables.tf),
[bootstrap inputs](../terraform/bootstrap/variables.tf),
[deployment workflow](../.github/workflows/terraform-layer.yml).

## Node enrollment lifecycle

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

Enrollment key rotation leaves existing nodes in place: the upstream host module
ignores cloud-init `user_data` changes. New and replacement nodes receive the
current run's key.
