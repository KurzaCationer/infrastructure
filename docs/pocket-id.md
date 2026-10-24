# Pocket ID

Pocket ID is served at `https://auth.kurza.nl`. Cloudflare must use **Full
(strict)**; disable Rocket Loader and interactive challenges on OIDC endpoints.

## Administrator enrollment

Complete `https://auth.kurza.nl/setup` immediately after first deployment.
The first visitor can claim the administrator account. Register a recovery
passkey as well as your primary passkey.

Add your account to **argocd-admins** in Pocket ID, then choose **Log in via
Pocket ID** at `https://argocd.<your-tailnet>.ts.net`.
Other users have no default Argo CD permissions. CLI SSO has no localhost
callback configured; retain local Argo CD admin access.

## Troubleshooting

With the [cluster kubeconfig](access.md):

```sh
kubectl -n argocd get application pocket-id
kubectl -n pocket-id get bitwardensecret,pvc,pods,httproute
kubectl -n pocket-id rollout status deployment/pocket-id --timeout=300s
curl --fail https://auth.kurza.nl/.well-known/openid-configuration
```

For deployment timeouts, check Bitwarden project permissions, PVC binding,
certificates, Gateway/HTTPRoute status and Cloudflare DNS before rerunning.

If operator logs show `set-by-bootstrap`, verify the Application source contains
the generated UUID patches, terminate the stale Argo CD operation and sync the
current source. Keep the existing keys.

## Recovery and upgrades

Automated Pocket ID backups are not configured. Back up the database and its
[matching encryption key](pocket-id-encryption-key.md) together. Deleting the
namespace or PVC can delete the data. Retired resources require manual removal.

Retain the identity state and Bitwarden client-secret record. Pocket ID cannot
return an existing OIDC client secret.

Verify API provisioning, passkey enrollment and browser sign-in after upgrades;
keep a working local Argo CD admin session.

## Hostname changes

Passkeys are tied to the Pocket ID hostname. Choose it before enrolling users.
A hostname change must update the workload's `APP_URL` and HTTPRoute, the bootstrap
`pocket_id` output, the workflow discovery check, the ingress validation check,
and public DNS/TLS configuration.

[Resource ownership](architecture.md) · [Teardown](operations.md#destroy)
