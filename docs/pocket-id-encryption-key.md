# Pocket ID encryption key

Keep `pocket-id-encryption-key` in Bitwarden for the lifetime of the Pocket ID
database. Back up the key with the data; restoring data requires the matching key.
The key also exists in bootstrap Terraform state.

## Recovery

If state is lost and the Bitwarden record survives, import it before applying:

```sh
terraform -chdir=terraform/bootstrap import bitwarden-secrets_secret.pocket_id_encryption EXISTING_BITWARDEN_SECRET_UUID
```

Requires the [bootstrap inputs and credentials](development.md#bootstrap).
Keep key values out of Git, command history and logs.

Do not replace the key during ordinary credential rotation. Any key change
requires a supported Pocket ID migration and a recoverable copy of the original
key and data.

## Retirement

Bootstrap destroy is blocked by `prevent_destroy` on the encryption-key resource.
Export or retire the Pocket ID data before removing that protection and running
[teardown](operations.md#destroy). Removing protection allows deletion of the
Bitwarden record.
