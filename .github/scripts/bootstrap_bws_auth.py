"""Initialize namespace-local BWS authentication without exposing token values."""

import base64
import json
import os
import subprocess
import sys


NAMESPACES = ("cert-manager", "external-dns")


def kubectl(arguments, manifest=None):
    result = subprocess.run(
        ["kubectl", "--request-timeout=30s", *arguments],
        input=json.dumps(manifest) if manifest else None,
        capture_output=True, text=True, timeout=330,
    )
    if result.returncode:
        # Kubernetes errors can echo submitted Secret payloads. Never log them.
        raise RuntimeError("Kubernetes authentication setup or BWS synchronization failed.")


def bootstrap():
    token = os.environ.get("TF_VAR_bitwarden_operator_access_token", "")
    if not token.strip():
        raise ValueError("The existing BWS operator access token is required.")
    encoded = base64.b64encode(token.encode()).decode()
    for namespace in NAMESPACES:
        kubectl(["apply", "--server-side", "--field-manager=bws-auth-bootstrap", "-f", "-"], {
            "apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace},
        })
        kubectl([
            "apply", "--server-side", "--field-manager=bws-auth-bootstrap", "--force-conflicts", "-f", "-",
        ], {
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "bitwarden-auth", "namespace": namespace},
            "data": {"token": encoded},
        })
    for namespace in NAMESPACES:
        kubectl([
            "wait", "--namespace", namespace, "--for=create",
            "secret/cloudflare-api-token", "--timeout=300s",
        ])
    print("BWS authentication configured and Cloudflare credentials synchronized in both namespaces.")


def main():
    try:
        bootstrap()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        # Exception details from external processes may contain credentials.
        print(f"::error::BWS authentication initialization failed ({type(error).__name__}).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
