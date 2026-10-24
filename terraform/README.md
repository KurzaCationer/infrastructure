# Terraform layers

Documentation: [setup](../docs/setup.md), [access](../docs/access.md),
[local Terraform runs](../docs/development.md) and [operations](../docs/operations.md).

| Layer | Responsibility | S3 state key |
| --- | --- | --- |
| [`cluster/`](cluster/) | Single-node k3s cluster, Hetzner networking, Cilium and private Tailscale node transport | `cluster/terraform.tfstate` |
| [`bootstrap/`](bootstrap/) | Bitwarden operator, OAuth secret mapping, Tailscale operator and private Argo CD ingress | `bootstrap/terraform.tfstate` |
| [`identity/`](identity/) | Pocket ID OIDC client/group, generated Argo CD client credentials and SSO configuration | `identity/terraform.tfstate` |

Apply **cluster → bootstrap → identity**; destroy **identity → bootstrap → cluster**. All layers use
the existing S3 bucket with native lock files. Bootstrap consumes the cluster's
sensitive kubeconfig output through remote state.

Image snapshots are built separately using
[`cluster/hcloud-init/`](cluster/hcloud-init/README.md). Terraform selects a
matching snapshot; it does not run Packer.

Inputs and defaults: [`cluster/variables.tf`](cluster/variables.tf),
[`bootstrap/variables.tf`](bootstrap/variables.tf) and
[`identity/variables.tf`](identity/variables.tf). Provider constraints and
state backend definitions live in each layer's `versions.tf`; pinned Helm chart
and module versions live in each layer's `main.tf`.
