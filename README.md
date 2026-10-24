# Infrastructure

Single-node k3s on Hetzner Cloud, managed with Terraform and Argo CD.
Administration requires Tailscale. Node maintenance and replacement cause downtime.

Run **Terraform Apply** manually on the default branch to deploy.
Argo CD syncs application changes from `main`.

- [Setup](docs/setup.md): accounts, credentials and first deployment.
- [Access](docs/access.md): kubeconfig and Argo CD login.
- [Operations](docs/operations.md): ingress, maintenance and teardown.
- [Credentials](docs/security.md): rotation and state protection.
- [Pocket ID](docs/pocket-id.md): enrollment, recovery and troubleshooting.
- [Local Terraform](docs/development.md): inputs and validation.
- [Terraform layers](terraform/README.md): state and deployment order.
- [Image builds](terraform/cluster/hcloud-init/README.md): snapshots and signing keys.
