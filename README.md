# Infrastructure

A single-node k3s cluster on Hetzner Cloud, provisioned with Terraform and
managed through GitHub Actions and Argo CD. Tailscale provides private admin
access; Bitwarden Secrets Manager supplies credentials.

## Stack

- **Cluster:** one schedulable `cx23` control-plane node in `nbg1`, with Cilium
  networking and Gateway API. No worker nodes.
- **Private platform:** Bitwarden and Tailscale operators, plus Argo CD at
  `https://argocd.<your-tailnet>.ts.net`.
- **GitOps:** CloudNativePG, ExternalDNS, wildcard certificates, a shared public
  Gateway, `test.kurza.nl`, and the Quad assignment application.
- **Public traffic:** Cloudflare proxies HTTPS to Cilium; the origin firewall
  accepts public web traffic only from Cloudflare ranges.

Terraform applies **cluster → bootstrap**, then Argo CD reconciles the
applications in [`argocd/`](argocd/). Terraform retains ownership of the bootstrap
releases. SSH and the Kubernetes API are accessible over Tailscale.

The cluster has no redundancy. Maintenance and node replacement cause downtime. Automatic OS and Kubernetes upgrades are disabled. The pinned
Kube-Hetzner module marks Cilium with Tailscale transport as experimental.

## Deployment

[Setup](docs/setup.md) covers accounts, credentials, GitHub settings and base
images. The S3 state bucket and matching Hetzner snapshots must exist before deployment.

Deploy changes by manually running **Terraform Apply** on the default branch.
Pull requests validate configuration; pushes do not deploy Terraform. Argo CD
reconciles its applications automatically from `main`.

| Documentation | Contents |
| --- | --- |
| [Setup](docs/setup.md) | Prerequisites and initial deployment |
| [Access and verification](docs/access.md) | Kubeconfig, cluster checks and Argo CD login |
| [Architecture](docs/architecture.md) | Networking, resource ownership and repository layout |
| [Operations](docs/operations.md) | Applications, public ingress, maintenance and teardown |
| [Local development](docs/development.md) | Local Terraform runs and validation |
| [Security and credentials](docs/security.md) | Secret storage, credential rotation and enrollment keys |

## Layout

| Path | Contents |
| --- | --- |
| [`terraform/`](terraform/README.md) | Cluster and bootstrap layers, each with separate S3 state |
| [`terraform/cluster/hcloud-init/`](terraform/cluster/hcloud-init/README.md) | Packer image builds and verified security bundle |
| [`argocd/`](argocd/) | GitOps Applications, platform resources and controller values |
| [`scripts/`](scripts/) | Cluster checks and admin kubeconfig retrieval for Bash and Windows |
| [`.github/workflows/`](.github/workflows/) | Validation, image builds, apply and destroy workflows |
| [`docs/`](docs/) | Setup, architecture and administration guides |
