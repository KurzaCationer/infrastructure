# Pocket ID encryption key

Terraform generates and stores the persistent encryption key used by Pocket ID.
Commands assume the repository root and the configured bootstrap backend.

## Creation and storage

The bootstrap resource `bitwarden-secrets_secret.pocket_id_encryption` generates
a 64-character random alphanumeric key and creates `pocket-id-encryption-key`
in the project selected by `BWS_IDENTITY_PROJECT_ID`. The cluster's Bitwarden
operator synchronizes it to `pocket-id/pocket-id` under `encryption-key`.
Pocket ID reads the mounted file through `ENCRYPTION_KEY_FILE`.

Terraform state contains the key value. Git and Helm values contain only its
Bitwarden UUID. Restrict access to the S3 state bucket and Bitwarden project.
Keep the same key for the lifetime of the Pocket ID data; recreating the
Deployment or rerunning Terraform does not require a new key.

## Recovery

Preserve the key alongside Pocket ID data backups. Restoring data
without the matching key prevents Pocket ID from decrypting stored material.
If Terraform state is lost but the Bitwarden record survives, import that
record into bootstrap before applying rather than generating a replacement:

```sh
terraform -chdir=terraform/bootstrap import bitwarden-secrets_secret.pocket_id_encryption EXISTING_BITWARDEN_SECRET_UUID
```

Import requires the bootstrap variables, AWS credentials and Bitwarden provider
credentials described in [local development](development.md#bootstrap).
Keep the key out of Git, command history and logs.

## Rotation and deliberate retirement

Keep the existing key during ordinary credential rotation. Coordinate
any key change with Pocket ID's supported encryption-key migration procedure
and retain a recoverable copy of the original key and data.

`prevent_destroy = true` blocks Terraform replacement and destruction of this
record, including a full bootstrap destroy. For deliberate permanent retirement,
first export or retire the Pocket ID data. Only then remove that lifecycle
protection in a reviewed change and run the normal teardown sequence. Removing
protection permits the Bitwarden record to be deleted; it is not a rotation.
