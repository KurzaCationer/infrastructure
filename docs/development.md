# Local development

[Home](../README.md) · [Setup](setup.md) · [Access](access.md) · [Architecture](architecture.md) · [Operations](operations.md) · [Development](development.md) · [Security](security.md)

Commands run from the repository root. CI deployment is documented in [setup](setup.md).

## Local Terraform runs

### Cluster

Local plans and applies require a tailnet connection and AWS authentication.
Export `TF_VAR_tailscale_magicdns_domain` and a fresh `TF_VAR_tailscale_auth_key` for
durable nodes tagged `tag:kurza-cluster`. Revoke the enrollment key afterward,
including on failure. The federation helper requires GitHub Actions OIDC and
runs in CI.

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
Supply the BWS operator token through
`TF_VAR_bitwarden_operator_access_token`. This variable is sensitive and ephemeral;
keep it available for both planning and applying a saved plan, including destroy
runs. Set `TF_VAR_bitwarden_operator_access_token_revision` to a positive integer
(default `1`) and increment it when rotating the token.

Plan and apply:

```sh
terraform -chdir=terraform/bootstrap plan -out=deployment.tfplan
terraform -chdir=terraform/bootstrap apply deployment.tfplan
```

Bootstrap's variables default to US Bitwarden endpoints; override them for
EU/self-hosted deployments. The token is supplied through the environment.

## Validation

Validation runs without cloud credentials:

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

Manifest checks require Helm and `PyYAML==6.0.3`:

```sh
python3 .github/scripts/check_argocd.py
python3 .github/scripts/check_public_ingress.py
```

The Argo CD check renders the pinned chart and rejects public Services, host
ports and unexpected ingress routes. Chart, module and provider downloads need
network access.

Image bundle integrity (Bash with `sha256sum`):

```sh
cd terraform/cluster/hcloud-init
sha256sum --check security-bundle.sha256
```
