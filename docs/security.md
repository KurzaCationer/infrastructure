# Credentials

Restrict access to Terraform state, saved plans, kubeconfigs and backups.
State includes cluster credentials, generated identity secrets and potentially
node enrollment keys. Enrollment keys also appear in Hetzner cloud-init data.
Historical S3 state versions retain old credentials.

## Credential rotation

| Credential | Action |
| --- | --- |
| Tailscale operator OAuth | Update Bitwarden, wait for synchronization, then run `kubectl -n tailscale rollout restart deployment/operator`. |
| Bitwarden operator token | Update `BWS_OPERATOR_ACCESS_TOKEN`, increment `BWS_OPERATOR_ACCESS_TOKEN_REVISION`, then run **Terraform Apply**. |
| Pocket ID encryption key | Preserve it with the database; follow the [key recovery and retirement reference](pocket-id-encryption-key.md). |

The operator token must be available during both plan and apply, including
destroy. Its rotation applies to all bootstrap-managed `bitwarden-auth` Secrets.

## Node enrollment

Local applies require a fresh enrollment key for durable nodes tagged
`tag:kurza-cluster`. Revoke it after use, including failed runs.

If CI enrollment-key cleanup fails, revoke the key in Tailscale. Keys expire
after one hour; revocation leaves enrolled nodes connected.

## Legacy auth Secret migration

Only for installations created by the old bootstrap script:

```sh
terraform -chdir=terraform/bootstrap import kubernetes_namespace_v1.tailscale tailscale
kubectl -n tailscale delete secret bitwarden-auth
terraform -chdir=terraform/bootstrap apply
```

Supply the [bootstrap inputs](development.md#bootstrap) before running this.
Secret synchronization pauses until apply recreates the Secret. Do not import
the old auth Secret: its token can enter state. Rotate credentials previously
stored in Terraform or Helm.

[Packer signing-key maintenance](../terraform/cluster/hcloud-init/keys/README.md)
