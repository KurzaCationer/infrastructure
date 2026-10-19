"""Exercise enrollment lifecycle and failure cleanup without real credentials/network."""

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit

import tailscale_enrollment as enrollment


def response(value):
    return io.BytesIO(json.dumps(value).encode())


class EnrollmentTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.env_file = Path(directory.name) / "env"
        self.output_file = Path(directory.name) / "outputs"
        env = {
            "TS_NODE_CLIENT_ID": "node-client",
            "TS_NODE_AUDIENCE": "node-audience",
            "ACTIONS_ID_TOKEN_REQUEST_URL": "https://oidc.example/token?existing=1",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "github-request-token",
            "GITHUB_ENV": str(self.env_file),
            "GITHUB_OUTPUT": str(self.output_file),
            "TS_NODE_KEY_ID": "test-key-id",
        }
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, env, clear=True).start()
        self.logs = io.StringIO()
        patch("sys.stdout", self.logs).start()

    def test_create_federates_and_exports_only_short_lived_durable_node_key(self):
        with patch.object(enrollment, "urlopen", side_effect=[
            response({"value": "test-jwt"}),
            response({"access_token": "test-api-token"}),
            response({"id": "test-key-id", "key": "test-enrollment-key"}),
        ]) as transport:
            enrollment.create()
        requests = [call.args[0] for call in transport.call_args_list]
        self.assertEqual(parse_qs(urlsplit(requests[0].full_url).query),
                         {"existing": ["1"], "audience": ["node-audience"]})
        self.assertEqual(requests[0].get_header("Authorization"), "Bearer github-request-token")
        self.assertEqual(parse_qs(requests[1].data.decode()),
                         {"client_id": ["node-client"], "jwt": ["test-jwt"]})
        self.assertEqual(requests[2].get_header("Authorization"), "Bearer test-api-token")
        payload = json.loads(requests[2].data)
        self.assertEqual(payload["expirySeconds"], 3600)
        self.assertEqual(payload["capabilities"]["devices"]["create"], {
            "reusable": True, "ephemeral": False, "preauthorized": True,
            "tags": ["tag:kurza-cluster"],
        })
        self.assertEqual(self.env_file.read_text(), "TF_VAR_tailscale_auth_key=test-enrollment-key\n")
        self.assertEqual(self.output_file.read_text(), "key_id=test-key-id\n")
        ordinary_logs = "\n".join(line for line in self.logs.getvalue().splitlines()
                                  if not line.startswith("::add-mask::"))
        for secret in ("test-jwt", "test-api-token", "test-enrollment-key"):
            self.assertNotIn(secret, ordinary_logs)
            self.assertIn(f"::add-mask::{secret}", self.logs.getvalue())

    def test_revoke_uses_fresh_federation_and_tolerates_already_absent_key(self):
        with patch.object(enrollment, "urlopen", side_effect=[
            response({"value": "fresh-jwt"}),
            response({"access_token": "fresh-api-token"}),
            HTTPError("https://api.tailscale.com", 404, "absent", {}, None),
        ]) as transport:
            enrollment.revoke()
        request = transport.call_args.args[0]
        self.assertEqual(request.method, "DELETE")
        self.assertTrue(request.full_url.endswith("/keys/test-key-id"))
        self.assertEqual(request.get_header("Authorization"), "Bearer fresh-api-token")

    def test_bad_key_response_preserves_id_for_cleanup_without_exporting_secret(self):
        with patch.object(enrollment, "request_json", return_value={"id": "test-key-id", "key": "bad\nkey"}), \
                patch.object(enrollment, "access_token", return_value="test-api-token"):
            with self.assertRaises(ValueError):
                enrollment.create()
        self.assertEqual(self.output_file.read_text(), "key_id=test-key-id\n")
        self.assertFalse(self.env_file.exists())

    def test_revoke_accepts_success_without_a_json_object(self):
        for body in (b"", b"\n", b"OK", b"null", b"{}"):
            with self.subTest(body=body), patch.object(enrollment, "urlopen", side_effect=[
                response({"value": "fresh-jwt"}),
                response({"access_token": "fresh-api-token"}),
                io.BytesIO(body),
            ]):
                enrollment.revoke()

    def test_revoke_still_rejects_http_failure(self):
        with patch.object(enrollment, "access_token", return_value="test-api-token"), \
                patch.object(enrollment, "urlopen", side_effect=HTTPError(
                    "https://api.tailscale.com", 403, "forbidden", {}, None)):
            with self.assertRaisesRegex(RuntimeError, "HTTP 403"):
                enrollment.revoke()

    def test_revoke_still_requires_json_federation_response(self):
        with patch.object(enrollment, "urlopen", return_value=io.BytesIO(b"invalid")):
            with self.assertRaisesRegex(RuntimeError, "Invalid JSON response from GET"):
                enrollment.revoke()

    def test_api_failure_is_not_retried_or_printed_with_response_body(self):
        error = HTTPError("https://api.tailscale.com", 403, "secret-error-body", {},
                          io.BytesIO(b"secret-response-body"))
        errors = io.StringIO()
        with patch.object(enrollment, "urlopen", side_effect=error) as transport, \
                patch.object(enrollment.sys, "argv", ["script", "create"]), \
                contextlib.redirect_stderr(errors):
            self.assertEqual(enrollment.main(), 1)
        self.assertEqual(transport.call_count, 1)
        self.assertNotIn("secret", errors.getvalue())
        self.assertFalse(self.env_file.exists())


if __name__ == "__main__":
    unittest.main()
