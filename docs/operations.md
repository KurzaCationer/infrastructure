# Operations

[Home](../README.md) · [Setup](setup.md) · [Access](access.md) · [Architecture](architecture.md) · [Operations](operations.md) · [Development](development.md) · [Security](security.md)

Commands assume the repository root and the [cluster kubeconfig](access.md#verify-bootstrap-and-sign-in).

Rerun **Terraform Apply** on the default branch to deploy configuration changes.
OS and Kubernetes upgrades are manual. Snapshot rebuilds and node replacement
are separate operations; replacing the single node causes downtime.

Argo CD automatically reconciles the public platform from the repository default
branch. Terraform retains ownership of its existing bootstrap releases.

## PostgreSQL operator

Argo CD installs the [CloudNativePG operator](https://cloudnative-pg.io/charts/)
from the official Helm repository using chart **0.29.1** (operator **1.30.1**).
The `cloudnative-pg` child Application creates `cnpg-system`, installs the CRDs
with server-side apply, and runs one operator replica with cluster-wide scope.
Values: `argocd/values/cloudnative-pg.yaml`. The operator is owned by Argo CD.

The root Application discovers the operator Application from `argocd/` on `main`.
Verify with `kubectl -n argocd get application cloudnative-pg`,
`kubectl -n cnpg-system rollout status deployment/cloudnative-pg --timeout=180s`
and `kubectl get crd clusters.postgresql.cnpg.io`.

Databases use separate CloudNativePG `Cluster` resources with their own storage,
credentials and backup settings. The operator must be healthy before the first
database sync.
Removing the operator Application cascades to its chart resources, including
CRDs; deleting those CRDs also deletes their custom resources. Database clusters must be
retired before operator removal.

## Quad assignment

The `quad-assignment` child Application watches
`deploy/overlays/production` on `main` in
[`KurzaCationer/quad-assignment`](https://github.com/KurzaCationer/quad-assignment).
That repository owns the frontend/backend Deployments, database, labelled
Namespace and HTTPRoute for `quad.dylannas.nl`. Its CI opens deployment pull
requests; Argo CD reconciles the image references after those PRs are merged.

The Application enables self-healing and server-side apply. Automatic pruning
is disabled and the Application has no cascading-deletion finalizer to protect
the database. Retired resources need manual removal.
The assignment repository must provide the production overlay and namespace,
and CloudNativePG must be healthy before the first deployment. Configure Argo CD
read credentials if the assignment repository is private. Until the overlay is
available on `main`, Argo CD will report a source/rendering error.

Platform validation checks this Application's source and destination locally;
the assignment repository's CI validates the external Kustomize overlay.

## Application ingress

The Terraform-seeded root Application loads the child Applications under
`argocd/`. They configure the existing cert-manager with Let's Encrypt DNS-01
for `*.dylannas.nl` and `*.kurza.nl`, install ExternalDNS, and deploy
`test.kurza.nl`. Cloudflare proxies traffic to Cilium on the existing node IP;
public ports 80/443 accept only Cloudflare's published IPv4/IPv6 ranges.

Cloudflare configuration:

1. Give the Cloudflare token **Zone / DNS / Edit** and **Zone / Zone / Read** for
   only these two zones. Its Bitwarden UUID is in
   `argocd/platform/ingress/cloudflare-credentials.yaml`. Grant the existing BWS
   operator machine account read access. Set both Cloudflare zones to **Full
   (strict)** with Universal SSL enabled; resolve any existing `test.kurza.nl`
   DNS conflict and ensure CAA records, if present, permit `letsencrypt.org`.
2. Merge and run **Terraform Apply** once to configure the firewall/Cilium and
   root Application. Argo CD then reconciles `argocd/` automatically. If the
   repository is private, first configure its read-only credentials in Argo CD.
3. Terraform writes the same BWS operator token into `tailscale`, `cert-manager`
   and `external-dns` before Argo CD starts its applications. The existing
   operator-token revision controls rotation in all three namespaces.

Deployment checks: `kubectl -n argocd get applications`, both certificates
`Ready` in `public-ingress`, and `https://test.kurza.nl` reachable through
Cloudflare. The following direct-origin request should fail outside the tailnet:

```sh
ORIGIN_IP=$(terraform -chdir=terraform/cluster output -raw public_ingress_ipv4)
curl --connect-timeout 5 --max-time 10 --resolve "test.kurza.nl:443:$ORIGIN_IP" https://test.kurza.nl
```

The ACME email is `mail@kurza.nl`; TLS/ACME keys stay in Kubernetes. The browser
shows Cloudflare's edge certificate; Full (strict) validates the Let's Encrypt
origin certificate. New applications reuse the shared Gateway and namespace/route opt-in labels
from the test manifests. Removing the
`https-test` Application from `argocd/kustomization.yaml` removes the example.
ExternalDNS retains DNS records on removal (`upsert-only`); remove retired names
and their ownership TXT records manually. Review Cloudflare IP ranges in
`terraform/cluster/cloudflare.tf` when [Cloudflare updates them](https://www.cloudflare.com/ips/).

## Destroy

Run **Terraform Destroy** manually on the default branch with confirmation
input `destroy`. It destroys **bootstrap -> cluster**, stopping if either
layer fails, and shares the deployment concurrency lock so deploy and destroy
cannot overlap. Each layer creates a saved destroy plan and applies that plan
using the same backend, credentials, and private network access as deployment.
The cluster job also reuses the short-lived enrollment-key creation and revocation
lifecycle, so the same node federation settings are required.

Destruction removes resources managed by these Terraform states. The existing S3
state bucket and separately built Hetzner snapshots remain.
