# Resource ownership

| Configuration | Owner |
| --- | --- |
| Cluster, networking and firewall | Terraform cluster |
| Bitwarden and Tailscale operators, Argo CD Helm release | Terraform bootstrap |
| Pocket ID keys and namespace | Terraform bootstrap |
| Argo CD OIDC client, group and `argocd-cm/oidc.config` | Terraform identity |
| Application workloads and public ingress | Argo CD |

Keep `oidc.config` out of bootstrap Helm values. Moving resources between
Terraform and Argo CD requires an ownership migration.

[Terraform layers](../terraform/README.md) · [Operations](operations.md)
