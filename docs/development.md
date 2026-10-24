# Local Terraform

Run commands from the repository root. Requires Terraform **>= 1.16.6, < 2.0**,
AWS credentials for the state bucket and a tailnet connection.

Apply **cluster → bootstrap → identity**. Pocket ID must be ready before identity.

## Inputs

Set `BW_ACCESS_TOKEN` and `BW_ORGANIZATION_ID` for Bitwarden.
For EU/self-hosted instances, also set `BW_API_URL` and `BW_IDENTITY_API_URL`.
The account needs read access to cluster credentials and read/write access to
the identity project.

### Cluster

Set:

- `TF_VAR_bitwarden_secret_ids`: the `BWS_SECRET_IDS` JSON from [setup](setup.md).
- `TF_VAR_tailscale_magicdns_domain`: the tailnet domain.
- `TF_VAR_tailscale_auth_key`: a fresh key for durable `tag:kurza-cluster` nodes.

Revoke the enrollment key after the run, including failures. Use a location in
`eu-central` and build a snapshot matching the server architecture before apply.
Changing architecture replaces the node.

### Bootstrap

Set:

- `TF_VAR_state_bucket` and `TF_VAR_aws_region`.
- `TF_VAR_tailscale_magicdns_domain`.
- `TF_VAR_bitwarden_organization_id`.
- `TF_VAR_tailscale_operator_secret_ids`: the `BWS_OPERATOR_SECRET_IDS` JSON.
- `TF_VAR_bitwarden_identity_project_id`.
- `TF_VAR_bitwarden_operator_access_token`.
- `TF_VAR_bitwarden_operator_access_token_revision`: increment on token rotation.

For EU/self-hosted Bitwarden, also set `TF_VAR_bitwarden_api_url` and
`TF_VAR_bitwarden_identity_url`.

Keep the operator token available during both plan and apply, including destroy.
AWS credentials must also read cluster state.

### Identity

Set `TF_VAR_state_bucket` and `TF_VAR_aws_region`.
AWS credentials must read both cluster and bootstrap state.

## Commands

Replace `LAYER` with `cluster`, `bootstrap` or `identity`:

```sh
terraform -chdir=terraform/LAYER init -reconfigure -backend-config="bucket=YOUR_BUCKET" -backend-config="region=YOUR_REGION"
terraform -chdir=terraform/LAYER plan -out=deployment.tfplan
terraform -chdir=terraform/LAYER apply deployment.tfplan
```

Commit provider lock files. Keep state, plans, credentials and local variable
files out of Git.

## Validation

Requires network access for module, provider and chart downloads.
Manifest checks also require Helm and `PyYAML==6.0.3`.

```sh
terraform fmt -check -recursive terraform
terraform -chdir=terraform/cluster init -backend=false
terraform -chdir=terraform/cluster validate
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/identity init -backend=false
terraform -chdir=terraform/identity validate
terraform -chdir=terraform/identity test
python3 .github/scripts/test_tailscale_enrollment.py
python3 .github/scripts/check_argocd.py
python3 .github/scripts/check_public_ingress.py
python3 scripts/tests/test_cluster_scripts.py
```
