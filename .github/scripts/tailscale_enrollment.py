"""Create/revoke short-lived node enrollment keys through GitHub OIDC."""

import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen


API = "https://api.tailscale.com/api/v2"


def single_line(value, name):
    if not isinstance(value, str) or not value or "\r" in value or "\n" in value:
        raise ValueError(f"{name} must be a non-empty single-line value.")
    return value


def required(name):
    return single_line(os.environ.get(name), name)


def request_json(url, *, method="GET", headers=None, data=None, allow_missing=False,
                 expect_json=True):
    request = Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urlopen(request, timeout=30) as response:
            if not expect_json:
                return {}
            body = response.read()
            result = json.loads(body) if body else {}
            if not isinstance(result, dict):
                raise ValueError("Expected a JSON object.")
            return result
    except HTTPError as error:
        if allow_missing and error.code == 404:
            return {}
        # Response bodies may contain credentials; never print them.
        raise RuntimeError(f"{method} {urlsplit(url).hostname} returned HTTP {error.code}.") from None
    except (URLError, TimeoutError):
        raise RuntimeError(f"Cannot reach {urlsplit(url).hostname}.") from None
    except (ValueError, UnicodeError):
        raise RuntimeError(f"Invalid JSON response from {method} {urlsplit(url).hostname}.") from None


def mask(value):
    escaped = value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::add-mask::{escaped}", flush=True)


def access_token():
    client_id = required("TS_NODE_CLIENT_ID")
    audience = required("TS_NODE_AUDIENCE")
    url = urlsplit(required("ACTIONS_ID_TOKEN_REQUEST_URL"))
    query = [(key, value) for key, value in parse_qsl(url.query) if key != "audience"]
    query.append(("audience", audience))
    identity = request_json(
        urlunsplit(url._replace(query=urlencode(query))),
        headers={"Authorization": f"Bearer {required('ACTIONS_ID_TOKEN_REQUEST_TOKEN')}"},
    )
    jwt = single_line(identity.get("value"), "GitHub identity token")
    mask(jwt)
    result = request_json(
        f"{API}/oauth/token-exchange",
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=urlencode({"client_id": client_id, "jwt": jwt}).encode(),
    )
    token = single_line(result.get("access_token"), "Tailscale API token")
    mask(token)
    return token


def append_setting(path, name, value):
    single_line(value, name)
    with open(path, "a", encoding="utf-8") as output:
        output.write(f"{name}={value}\n")


def create():
    output_path = required("GITHUB_OUTPUT")
    env_path = required("GITHUB_ENV")
    payload = {
        "expirySeconds": 3600,
        "description": "GitHub cluster provisioning",
        "capabilities": {"devices": {"create": {
            "reusable": True,
            "ephemeral": False,
            "preauthorized": True,
            "tags": ["tag:kurza-cluster"],
        }}},
    }
    result = request_json(
        f"{API}/tailnet/-/keys",
        method="POST",
        headers={"Authorization": f"Bearer {access_token()}", "Content-Type": "application/json"},
        data=json.dumps(payload).encode(),
    )
    # Record the ID first so cleanup can run even if exporting the key fails.
    append_setting(output_path, "key_id", result.get("id"))
    key = single_line(result.get("key"), "Tailscale enrollment key")
    mask(key)
    append_setting(env_path, "TF_VAR_tailscale_auth_key", key)
    print("Created a one-hour enrollment key for durable cluster nodes.")


def revoke():
    key_id = quote(required("TS_NODE_KEY_ID"), safe="")
    # Exchange a fresh identity token: the create step's API token may have expired.
    request_json(
        f"{API}/tailnet/-/keys/{key_id}",
        method="DELETE",
        headers={"Authorization": f"Bearer {access_token()}"},
        allow_missing=True,
        # Successful revocation needs only the HTTP status, not a JSON body.
        expect_json=False,
    )
    print("Enrollment key revoked or already absent.")


def main():
    try:
        if sys.argv[1:] == ["create"]:
            create()
        elif sys.argv[1:] == ["revoke"]:
            revoke()
        else:
            raise ValueError("Usage: tailscale_enrollment.py create|revoke")
    except (ValueError, RuntimeError, OSError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
