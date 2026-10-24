# Operations

Push or merge to `main` for infrastructure changes. **Terraform Apply** runs
automatically while `HCLOUD_INITIALIZED=true`; manual runs use the same gate.
Argo CD syncs application changes from `main`.

OS and Kubernetes upgrades are manual. The single node has no redundancy;
maintenance and replacement cause downtime. Rebuilding snapshots does not
update existing nodes.

## Application ingress

Cloudflare settings for `dylannas.nl` and `kurza.nl`:

- API token: **Zone / DNS / Edit** and **Zone / Zone / Read**, limited to these zones.
- Store its UUID in [cloudflare-credentials.yaml](../argocd/platform/ingress/cloudflare-credentials.yaml);
  grant the Bitwarden operator machine account read access.
- Enable **Full (strict)** and Universal SSL.
- Remove conflicting DNS records. If CAA records exist, allow `letsencrypt.org`.

New applications must use the shared Gateway and the namespace/route opt-in
labels in the test manifests.

With the [cluster kubeconfig](access.md):

```sh
kubectl -n argocd get applications
kubectl -n public-ingress get certificates
curl --fail https://test.kurza.nl
```

Certificates should be Ready. Direct-origin HTTPS should fail outside the tailnet:

```sh
ORIGIN_IP=$(terraform -chdir=terraform/cluster output -raw public_ingress_ipv4)
curl --connect-timeout 5 --max-time 10 --resolve "test.kurza.nl:443:$ORIGIN_IP" https://test.kurza.nl
```

Remove retired DNS names and their ownership TXT records manually; ExternalDNS
retains them. Keep the ranges in
[cloudflare.tf](../terraform/cluster/cloudflare.tf) current with Cloudflare's
published IP ranges.

## Databases and applications

CloudNativePG must be healthy before deploying databases:

```sh
kubectl -n cnpg-system rollout status deployment/cloudnative-pg --timeout=180s
```

Retire database clusters before removing the operator Application. Its removal
can delete CRDs and their custom resources.

Deploy Quad assignment changes through its repository's
`deploy/overlays/production` on `main`. Retired resources require manual removal.
Configure Argo CD read credentials if that repository is private.

[Pocket ID](pocket-id.md) has separate enrollment, backup and recovery requirements.

## Destroy

Export or retire persistent application data and
[retire the Pocket ID encryption key](pocket-id-encryption-key.md#retirement)
before teardown.

Run **Terraform Destroy** on the default branch with confirmation input `destroy`.
Keep deployment credentials and tailnet access available. Destruction runs
**identity → bootstrap → cluster**; Pocket ID must remain reachable until identity
finishes. For manual teardown, skip identity only if its state is empty.

Before teardown, the workflow sets `HCLOUD_INITIALIZED=destroying`, blocking
applies and new initialization while allowing destroy retries. Once all three
layers succeed, it sets the variable to `false`. Pushes and manual applies then
remain disabled until **Hetzner Cloud Initialization** succeeds again.

If teardown fails or is cancelled, leave `destroying` in place and retry
**Terraform Destroy**. If only the final variable update fails, rerun failed jobs
to complete it. Keep `INFRASTRUCTURE_VARIABLE_TOKEN` valid throughout teardown.

If Argo CD cleanup fails, inspect its Job logs in `argocd` before retrying.
Keep the Tailscale operator running until its resources are removed.

The S3 state bucket and separately built Hetzner snapshots remain after destroy.
