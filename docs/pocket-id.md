# Pocket ID and Argo CD sign-in

[Home](../README.md) · [Setup](setup.md) · [Access](access.md) · [Architecture](architecture.md) · [Operations](operations.md) · [Development](development.md) · [Security](security.md)

Pocket ID provides shared OpenID Connect (OIDC) authentication for public and
private applications. Argo CD uses it for browser sign-in while remaining
accessible only through Tailscale. Each additional application needs its own
client and callback URLs. Applications without OIDC support need a separate
authentication proxy.

Commands assume the repository root and the [cluster kubeconfig](access.md#verify-bootstrap-and-sign-in).
Replace `auth.example.com` and `<your-tailnet>.ts.net` with the configured
Pocket ID hostname and tailnet domain.

## Hostnames

Pocket ID uses one canonical HTTPS URL. Passkeys belong to that hostname;
choose it before enrolling users. Private applications can use the same issuer
without exposing their own endpoints publicly.

When adapting the deployment to another domain, keep these settings aligned:

| Configuration | Location |
| --- | --- |
| Pocket ID `APP_URL`, HTTPRoute hostname and Gateway listener reference | [`argocd/workloads/pocket-id/resources.yaml`](../argocd/workloads/pocket-id/resources.yaml) |
| Canonical URL consumed by the identity layer | [`terraform/bootstrap/outputs.tf`](../terraform/bootstrap/outputs.tf) |
| Discovery endpoint used by the deployment readiness check | [Terraform layer workflow](../.github/workflows/terraform-layer.yml) |
| Expected route hostname in manifest validation | [Public ingress checks](../.github/scripts/check_public_ingress.py) |

The hostname also needs matching [public ingress and DNS configuration](operations.md#application-ingress).
Argo CD's URL and callback are derived from `tailscale_magicdns_domain`.

## Provisioning

Set `BWS_IDENTITY_PROJECT_ID` to an existing Bitwarden Secrets Manager project
UUID. The machine account behind `BWS_ACCESS_TOKEN` needs **read/write** access
to that project; the account behind `BWS_OPERATOR_ACCESS_TOKEN` needs **read**
access. Bitwarden organization and endpoint settings apply to all three layers.
The GitHub Actions AWS role needs S3 access to the
`identity/terraform.tfstate` and `identity/terraform.tfstate.tflock` objects,
including listing `identity/*`, as described in [setup](setup.md#1-prepare-accounts-tools-and-aws-state).

Run **Terraform Apply** on the default branch. Deployment proceeds in order:

1. `cluster` provisions the Kubernetes infrastructure.
2. `bootstrap` generates Pocket ID's encryption and provisioning API keys in
   Bitwarden and supplies their UUIDs to Argo CD.
3. Argo CD reconciles the Pocket ID Deployment, secret mapping, persistent
   volume claim and HTTPRoute. ExternalDNS publishes the hostname through
   Cloudflare; the shared Gateway terminates origin TLS.
4. After the Deployment and OIDC discovery endpoint are ready, `identity`
   creates `argocd-admins`, the confidential PKCE client `argocd`, and its
   generated client secret. It stores the secret in Bitwarden and the labelled
   `argocd/argocd-pocket-id` Kubernetes Secret.
5. `identity` sets Argo CD's `oidc.config` after the credentials exist.

Credentials and their UUIDs are passed between layers automatically. Generated
secret values enter Terraform state; restrict access to the state bucket.
Encryption-key instructions are maintained separately in
[Pocket ID encryption key](pocket-id-encryption-key.md).

If the wait times out, check Bitwarden project permissions, `pocket-id` PVC
binding, certificates, Gateway/HTTPRoute status and Cloudflare DNS, then rerun
the workflow. Argo CD needs read access to the configured Git source revision.
Cloudflare Full (strict) remains required; disable Rocket Loader for this host
and avoid interactive Cloudflare challenges on OIDC endpoints.

## Enroll your administrator

Open `https://auth.example.com/setup` during first deployment and create the
administrator account. The first visitor can claim this account; complete setup
before leaving the service unattended. Register a passkey and a second passkey
for recovery. The provisioning API's synthetic user does not complete setup.

In Pocket ID, add your account to the Terraform-created **argocd-admins** group.
Group membership and personal passkeys are managed in Pocket ID; Terraform
manages the group and client definitions. Open
`https://argocd.<your-tailnet>.ts.net` and choose **Log in via Pocket ID**.
The registered callback is
`https://argocd.<your-tailnet>.ts.net/auth/callback`. Browser SSO is configured;
no localhost callback for CLI SSO is registered.

Argo CD stays private to Tailscale. Only the `argocd-admins` group receives its
administrator role; other Pocket ID users receive no default permissions.
The local Argo CD `admin` account remains enabled for recovery. Verify it still
works before testing SSO in a separate browser session.

## Verification

```sh
kubectl -n argocd get application pocket-id
kubectl -n pocket-id get bitwardensecret,pvc,pods,httproute
kubectl -n pocket-id rollout status deployment/pocket-id --timeout=300s
curl --fail https://auth.example.com/.well-known/openid-configuration
```

The discovery issuer must match the configured canonical URL. Verify passkey
enrollment and Argo CD sign-in in a browser after deployment.

## Resource ownership and storage

Bootstrap owns the `pocket-id` namespace, operator authentication, generated
keys, and existing Helm releases. Argo CD owns Pocket ID's workload. Identity
owns the OIDC client/group, client secret, labelled Kubernetes Secret and only
the `oidc.config` data field of `argocd-cm`. Helm owns the ConfigMap's remaining
fields. Do not add `oidc.config` to the bootstrap Helm values: that would give
two managers ownership of the same setting.

Pocket ID uses SQLite on a 10 GiB `hcloud-volumes` block volume. A `Recreate`
strategy prevents simultaneous writers during updates. Its Application has no
cascading deletion finalizer or automatic pruning, and its PVC is protected
from GitOps deletion. Automated backups are not configured. Deleting the
namespace or PVC can still delete the disk and data.

## Teardown and upgrades

Teardown order is **identity → bootstrap → cluster**, while Pocket ID's API is
still available. Bootstrap teardown intentionally stops at the protected
encryption key until it is deliberately retired; see the separate key guide.
The workflow stops on that failure rather than deleting the cluster. If the
identity layer was never applied, skip that empty layer during manual teardown.

The container version is pinned in the workload manifests; the independent
[`irashack/pocketid` provider](https://registry.terraform.io/providers/irashack/pocketid/3.1.4/docs)
is pinned in [`terraform/identity/versions.tf`](../terraform/identity/versions.tf).
Provider 3.1.4 documents testing through Pocket ID 2.18.0. Verify API provisioning
and browser sign-in when using a later release. Retain local Argo CD administrator
access during upgrades.
