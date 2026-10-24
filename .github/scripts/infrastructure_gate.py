"""Read lifecycle state live, after acquiring the workflow's deployment lock."""

import json
import os
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen

VARIABLE = "HCLOUD_INITIALIZED"


class RepositoryVariable:
    def __init__(self):
        token = os.environ.get("GH_TOKEN")
        if not token:
            raise RuntimeError("Set the INFRASTRUCTURE_VARIABLE_TOKEN repository secret (Variables: read/write).")
        self.url = f"{os.environ['GITHUB_API_URL']}/repos/{os.environ['GITHUB_REPOSITORY']}/actions/variables"
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
        }

    def request(self, method, suffix="", body=None):
        data = None if body is None else json.dumps(body).encode()
        request = Request(self.url + suffix, data=data, headers=self.headers, method=method)
        request.add_header("Content-Type", "application/json")
        with urlopen(request, timeout=30) as response:
            content = response.read()
            return json.loads(content) if content else None

    def read(self):
        # Listing distinguishes a missing variable from an inaccessible repository.
        page = 1
        while True:
            result = self.request("GET", f"?per_page=100&page={page}")
            for variable in result["variables"]:
                if variable["name"] == VARIABLE:
                    return variable["value"]
            if len(result["variables"]) < 100:
                return None
            page += 1

    def write(self, value, exists):
        self.request("PATCH" if exists else "POST", f"/{VARIABLE}" if exists else "",
                     {"name": VARIABLE, "value": value})


def transition(command, variable):
    state = variable.read()
    if state not in (None, "false", "true", "destroying"):
        raise RuntimeError(f"Unexpected {VARIABLE} value: {state!r}")
    if command == "check-apply":
        return state == "true"
    if command in ("require-apply", "require-destroy"):
        expected = "true" if command == "require-apply" else "destroying"
        if state != expected:
            raise RuntimeError(f"{command} blocked: {VARIABLE} is {state!r}.")
        return True
    if command in ("prepare-init", "enable"):
        if state == "destroying":
            raise RuntimeError("Finish Terraform Destroy before initializing again.")
        value = "true" if command == "enable" else (state or "false")
    elif command == "begin-destroy":
        if state not in ("true", "destroying"):
            raise RuntimeError("Run Hetzner Cloud Initialization before destroying.")
        value = "destroying"
    elif command == "finish-destroy":
        if state != "destroying":
            raise RuntimeError("Cannot finish destruction outside the destroying state.")
        value = "false"
    else:
        raise RuntimeError(f"Unknown gate command: {command}")
    variable.write(value, exists=state is not None)
    return True


def main():
    enabled = transition(sys.argv[1], RepositoryVariable())
    if sys.argv[1] == "check-apply":
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"enabled={str(enabled).lower()}\n")
        if not enabled:
            print("Deployment disabled; complete Hetzner Cloud Initialization first.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, HTTPError) as error:
        sys.exit(str(error))
