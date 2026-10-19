# Terraform layers

The [root README](../README.md) is the central guide for architecture,
[setup](../README.md#setup), GitHub settings, deployment, verification, local runs
and destruction. Start there before running either layer.

| Layer | Responsibility | S3 state key |
| --- | --- | --- |
| [`cluster/`](cluster/) | Single-node k3s cluster, Hetzner networking, Cilium and private Tailscale node transport | `cluster/terraform.tfstate` |
| [`bootstrap/`](bootstrap/) | Bitwarden operator, OAuth secret mapping, Tailscale operator and private Argo CD ingress | `bootstrap/terraform.tfstate` |

Apply **cluster → bootstrap**; destroy **bootstrap → cluster**. Both layers use
the existing S3 bucket with native lock files. Bootstrap consumes the cluster's
sensitive kubeconfig output through remote state.

Image snapshots are built separately using
[`cluster/hcloud-init/`](cluster/hcloud-init/README.md). Terraform selects a
matching snapshot; it does not run Packer.

For supported inputs and defaults, see [`cluster/variables.tf`](cluster/variables.tf)
and [`bootstrap/variables.tf`](bootstrap/variables.tf). Provider constraints and
state backend definitions live in each layer's `versions.tf`; pinned Helm chart
and module versions live in each layer's `main.tf`.
