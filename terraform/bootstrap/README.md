# Bootstrap

Requires the cluster state and tailnet access.

[Local inputs and commands](../../docs/development.md#bootstrap) · [Argo CD login](../../docs/access.md#argo-cd) · [Token rotation](../../docs/security.md#credential-rotation)

Apply bootstrap changes before destroying an older deployment so the installed
Argo CD release includes its cleanup hook. If cleanup fails, inspect the Job logs
in `argocd` before retrying; keep the Tailscale operator running until cleanup
finishes.

Bootstrap destruction also requires deliberate retirement of the
[Pocket ID encryption key](../../docs/pocket-id-encryption-key.md#retirement).
