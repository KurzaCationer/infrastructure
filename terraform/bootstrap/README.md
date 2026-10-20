# Platform bootstrap

Documentation: [setup](../../docs/setup.md),
[Argo CD login](../../docs/access.md#verify-bootstrap-and-sign-in),
[credential rotation](../../docs/security.md#credential-rotation) and
[local Terraform runs](../../docs/development.md#bootstrap).

This layer reads the cluster kubeconfig from S3 and installs Helm releases in
dependency order:

1. Bitwarden Secrets Manager operator in `sm-operator-system`.
2. The local `tailscale-credentials` chart, creating a `BitwardenSecret` mapping.
3. Tailscale operator in `tailscale`, mounting the synchronized `operator-oauth` Secret.
4. Argo CD in `argocd`, including the ingress ProxyGroup and private Ingress.

| File | Purpose |
| --- | --- |
| [`main.tf`](main.tf) | Remote state, providers, write-only Bitwarden auth Secret, releases and dependency order |
| [`variables.tf`](variables.tf) | Bucket, tailnet, Bitwarden endpoint and secret-UUID inputs |
| [`outputs.tf`](outputs.tf) | Private Argo CD URL |
| [`values/argocd.yaml`](values/argocd.yaml) | Argo CD settings, ingress ProxyClass/ProxyGroup and Tailscale Ingress |
| [`charts/tailscale-credentials/`](charts/tailscale-credentials/) | Maps only the operator OAuth secrets to `tailscale/operator-oauth` |

Terraform owns the `tailscale` namespace and `tailscale/bitwarden-auth` Secret.
The BWS token enters through the sensitive, ephemeral
`bitwarden_operator_access_token` variable and is written using `data_wo`, so it
is omitted from saved plans and state. CI supplies it during both plan and apply,
including destroy runs. Helm never receives the token or Tailscale credentials.
Increment `bitwarden_operator_access_token_revision` when rotating the token;
CI reads that revision from `BWS_OPERATOR_ACCESS_TOKEN_REVISION` (default `1`).

Terraform owns the bootstrap releases and their resources. GitOps manifests live
in `argocd/`. Moving bootstrap resources to Argo CD requires an ownership migration.

Argo CD's pre-delete Job removes its Ingress, ProxyGroup and ProxyClass in that
order and waits for their finalizers while the Tailscale operator is still
running. It also covers the named ProxyClass if it was created outside the
stored Helm manifest. A cleanup failure stops teardown before the operator is
removed. Inspect the Job's container logs in `argocd` before retrying. The hook
never strips finalizers. Its kubectl image is pinned to Kubernetes 1.36; keep it
compatible with the cluster when upgrading. Apply bootstrap changes before
destroying an existing deployment so Helm stores the hook in the installed
release.

Argo CD uses Tailscale Service `svc:argocd` at
`https://argocd.<your-tailnet>.ts.net`. Its Service remains `ClusterIP`; HTTPS
terminates on the proxy. The required tailnet policy, operator OAuth client and
Bitwarden accounts are documented in [setup](../../docs/setup.md#3-configure-the-operators-and-private-argo-cd-access).
Private access needs verification after Helm completes.

The ingress ProxyClass sets `TS_DEBUG_DISABLE_UDP_GSO=true`. On this deployment,
small requests worked but the JavaScript bundle took about 29 seconds to download;
disabling UDP segmentation offload reduced that to under one second. This matches
[Tailscale issue #20858](https://github.com/tailscale/tailscale/issues/20858).
The override is scoped to the ingress proxy pending an upstream fix. The
[proxy-device grant](../../docs/setup.md#3-configure-the-operators-and-private-argo-cd-access)
works around missing Service-host routes.
