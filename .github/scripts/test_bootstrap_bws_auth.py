"""Check unattended creation, rotation and safe failure without a cluster."""

import base64
import contextlib
import io
import json
import os
import subprocess
import unittest
from unittest.mock import patch

import bootstrap_bws_auth as auth


class AuthTests(unittest.TestCase):
    def test_creation_and_rotation_update_both_namespaces_via_stdin(self):
        for token in ("initial-machine-token", "rotated-machine-token"):
            with self.subTest(token=token), patch.dict(os.environ, {
                "TF_VAR_bitwarden_operator_access_token": token,
            }), patch.object(auth.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(auth.main(), 0)
                self.assertEqual(run.call_count, 6)
                manifests = [json.loads(call.kwargs["input"]) for call in run.call_args_list[:4]]
                secrets = [obj for obj in manifests if obj["kind"] == "Secret"]
                self.assertEqual({obj["metadata"]["namespace"] for obj in secrets}, set(auth.NAMESPACES))
                for secret in secrets:
                    self.assertEqual(base64.b64decode(secret["data"]["token"]).decode(), token)
                for call in run.call_args_list:
                    self.assertNotIn(token, " ".join(call.args[0]))
                    self.assertTrue(call.kwargs["capture_output"])
                for call in (run.call_args_list[1], run.call_args_list[3]):
                    self.assertIn("--server-side", call.args[0])
                    self.assertIn("--force-conflicts", call.args[0])
                for call in run.call_args_list[4:]:
                    self.assertIn("--for=create", call.args[0])
                    self.assertIn("secret/cloudflare-api-token", call.args[0])
                self.assertNotIn(token, output.getvalue())

    def test_failure_does_not_print_secret_payloads(self):
        with patch.dict(os.environ, {"TF_VAR_bitwarden_operator_access_token": "private-token"}), \
                patch.object(auth.subprocess, "run", return_value=subprocess.CompletedProcess(
                    [], 1, stdout="private-token", stderr="private-token")), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(auth.main(), 1)
            self.assertNotIn("private-token", errors.getvalue())

    def test_missing_cloudflare_credentials_fail_the_run(self):
        responses = [subprocess.CompletedProcess([], 0)] * 4 + [subprocess.CompletedProcess([], 1)]
        with patch.dict(os.environ, {"TF_VAR_bitwarden_operator_access_token": "machine-token"}), \
                patch.object(auth.subprocess, "run", side_effect=responses) as run, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(auth.main(), 1)
            self.assertEqual(run.call_count, 5)

    def test_missing_token_stops_before_any_cluster_calls(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(auth.subprocess, "run") as run, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(auth.main(), 1)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
