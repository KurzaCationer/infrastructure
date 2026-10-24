# Identity configuration

Apply after `cluster` and `bootstrap`, once Pocket ID's HTTPS discovery endpoint
is reachable. This layer reads their S3 remote states and creates Pocket ID's
Argo CD client/group, stores the generated client secret in Bitwarden and
Kubernetes, then enables direct OIDC in Argo CD.

Set `TF_VAR_state_bucket`, `TF_VAR_aws_region`, `BW_ACCESS_TOKEN` and
`BW_ORGANIZATION_ID`. Use the existing Bitwarden provider endpoint environment
variables for EU/self-hosted instances. The Bitwarden account needs read/write
access to the bootstrap identity project. The workstation also needs tailnet
access to Kubernetes and AWS read access to both prerequisite state files.

```sh
terraform -chdir=terraform/identity init -backend-config="bucket=YOUR_BUCKET" -backend-config="region=YOUR_REGION"
terraform -chdir=terraform/identity plan -out=deployment.tfplan
terraform -chdir=terraform/identity apply deployment.tfplan
```

Generated client-secret values and the provisioning API key enter sensitive
state. Do not print or upload state or saved plans. Client secrets cannot be
recovered from Pocket ID after creation; retain Terraform state and the
Bitwarden record. Importing only the client after state loss does not recover
its secret; restore state or deliberately issue and deploy a replacement.

Destroy this layer while Pocket ID and Kubernetes are still running, before
bootstrap. Group membership and personal passkey enrollment remain interactive.
See [Pocket ID setup](../../docs/pocket-id.md) for deployment, verification,
ownership, and the separately documented encryption-key lifecycle.
