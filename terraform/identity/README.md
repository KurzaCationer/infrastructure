# Identity

Requires applied cluster and bootstrap layers, tailnet access, and a reachable
Pocket ID discovery endpoint.

[Local inputs and commands](../../docs/development.md) · [Administrator enrollment](../../docs/pocket-id.md#administrator-enrollment)

Retain Terraform state and the Bitwarden client-secret record. Pocket ID cannot
return an existing client secret; importing the client alone will not recover it.

Destroy this layer before bootstrap, while Pocket ID and Kubernetes are running.
