# Architecture

[Home](../README.md) · [Setup](setup.md) · [Access](access.md) · [Architecture](architecture.md) · [Operations](operations.md) · [Development](development.md) · [Security](security.md)

The layers run in order: **cluster -> bootstrap**. Both use the existing S3 bucket
with separate state keys and native S3 locking. CI uses Terraform 1.16.6.

- `cluster`: Kube-Hetzner 3.2.1 with one schedulable `cx23` control-plane node in
  `nbg1`, running k3s and workloads together. No worker nodes. Automatic upgrades
  are disabled. Cilium supplies the CNI, kube-proxy replacement, and Gateway API
  controller; Traefik is disabled. The Cilium operator runs one replica.
- `bootstrap`: installs the Bitwarden and Tailscale Kubernetes operators and
  Argo CD, published privately as Tailscale Service `svc:argocd`.

The single node has no redundancy. Nodes enroll into Tailscale during
cloud-init. Public SSH and Kubernetes API firewall rules are disabled;
Terraform and operators connect using the node's tailnet MagicDNS name.
Nodes retain public addresses for outbound bootstrap and Tailscale connectivity.
Terraform persists `net.ipv4.conf.all.accept_local=1` on cluster nodes so
Tailscale's source validation settings do not break Cilium's transparent proxy.

The Terraform `bootstrap` layer reads the cluster kubeconfig from S3 and installs
Bitwarden Secrets Manager operator chart **2.0.3**, a `BitwardenSecret` mapping,
Tailscale operator **1.104.1**, then Argo CD chart **10.10.5**. Argo CD deploys
the CloudNativePG operator, ExternalDNS, wildcard certificates, a shared public
Gateway and the test application at `test.kurza.nl` from `argocd/`. Kube-Hetzner
installs cert-manager by default.
Terraform owns the bootstrap releases, including the ProxyGroup and ingress in
[`terraform/bootstrap/values/argocd.yaml`](../terraform/bootstrap/values/argocd.yaml).
Bootstrap seeds only the root `infrastructure` Argo CD Application, which watches
`argocd/` and creates its child Applications. It supplies the non-secret
Bitwarden organization UUID and public origin IP. Argo CD owns CloudNativePG
and public application resources. Bootstrap Helm values are stored in
`terraform/bootstrap/values/`.

Argo CD is available at `https://argocd.<your-tailnet>.ts.net` as Tailscale Service
`svc:argocd`. Its Kubernetes Service is `ClusterIP`; the Tailscale controller
handles ingress. There is no public Argo CD endpoint. HTTPS terminates on the
Tailscale proxy, which forwards HTTP to the internal service. Argo CD
authentication remains enabled.
The ProxyGroup runs one replica.
Its ProxyClass disables UDP segmentation offload to avoid stalled large downloads
on the deployed Cilium network path.

| Path | Responsibility |
| --- | --- |
| [`terraform/cluster/`](../terraform/cluster/) | Hetzner cluster, networking, firewall, Cilium and private node transport; state key `cluster/terraform.tfstate` |
| [`terraform/cluster/hcloud-init/`](../terraform/cluster/hcloud-init/) | Separate Packer snapshot builds and vendored security bundle |
| [`terraform/bootstrap/`](../terraform/bootstrap/) | Bitwarden and Tailscale operators, OAuth secret mapping and Argo CD; state key `bootstrap/terraform.tfstate` |
| [`terraform/bootstrap/values/argocd.yaml`](../terraform/bootstrap/values/argocd.yaml) | Terraform-owned Argo CD settings, ingress ProxyGroup and private Ingress |
| `argocd/` | Argo CD Application, AppProject, public platform chart and controller values |
| [`scripts/`](../scripts/) | Local cluster checks and admin kubeconfig retrieval for Bash and Windows |
| [`.github/workflows/`](../.github/workflows/) | Validation, manual image builds, apply and destroy workflows |
| [`.github/scripts/`](../.github/scripts/) | Enrollment-key lifecycle, Argo CD manifest checks and helper tests |
