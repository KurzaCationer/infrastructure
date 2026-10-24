# Terraform

Apply **cluster → bootstrap → identity**; destroy in reverse order.
Identity requires a running Pocket ID instance.

| Layer | State key |
| --- | --- |
| [cluster](cluster/) | `cluster/terraform.tfstate` |
| [bootstrap](bootstrap/) | `bootstrap/terraform.tfstate` |
| [identity](identity/) | `identity/terraform.tfstate` |

All layers use the existing S3 bucket. Preserve its state and version history.

[Setup](../docs/setup.md) · [Local runs](../docs/development.md) · [Teardown](../docs/operations.md#destroy)
