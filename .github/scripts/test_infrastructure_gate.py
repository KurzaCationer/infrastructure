"""Offline regression tests for the infrastructure lifecycle and live API reads."""

import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError

from infrastructure_gate import RepositoryVariable, VARIABLE, transition


class GateTests(unittest.TestCase):
    def variable(self, state):
        variable = Mock()
        variable.read.return_value = state
        return variable

    def test_apply_only_allowed_after_successful_init(self):
        for state in (None, "false", "true", "destroying"):
            with self.subTest(state=state):
                variable = self.variable(state)
                self.assertEqual(transition("check-apply", variable), state == "true")
                variable.write.assert_not_called()
                if state != "true":
                    with self.assertRaises(RuntimeError):
                        transition("require-apply", variable)

    def test_full_lifecycle_and_failed_destroy_retry(self):
        state = None
        variable = Mock()
        variable.read.side_effect = lambda: state

        def write(value, exists):
            nonlocal state
            self.assertEqual(exists, state is not None)
            state = value

        variable.write.side_effect = write
        transition("prepare-init", variable)
        self.assertEqual(state, "false")
        self.assertFalse(transition("check-apply", variable))
        transition("enable", variable)
        self.assertTrue(transition("require-apply", variable))
        transition("begin-destroy", variable)
        self.assertEqual(state, "destroying")
        self.assertFalse(transition("check-apply", variable))
        for command in ("prepare-init", "enable", "require-apply"):
            with self.assertRaises(RuntimeError):
                transition(command, variable)
        # A failed/cancelled teardown leaves this state and can be resumed.
        transition("begin-destroy", variable)
        transition("require-destroy", variable)
        transition("finish-destroy", variable)
        self.assertEqual(state, "false")
        self.assertFalse(transition("check-apply", variable))
        with self.assertRaises(RuntimeError):
            transition("require-apply", variable)

    def test_destroy_requires_initialization(self):
        for state in (None, "false"):
            variable = self.variable(state)
            with self.assertRaises(RuntimeError):
                transition("begin-destroy", variable)
            variable.write.assert_not_called()

    def test_retries_cannot_disable_a_new_initialization(self):
        variable = self.variable("true")
        with self.assertRaises(RuntimeError):
            transition("finish-destroy", variable)
        variable.write.assert_not_called()

    def test_unrecognized_state_fails_closed(self):
        with self.assertRaises(RuntimeError):
            transition("check-apply", self.variable("TRUE"))

    def test_api_failure_is_not_treated_as_missing_variable(self):
        variable = self.variable(None)
        variable.read.side_effect = HTTPError("https://example.test", 403, "Forbidden", {}, None)
        with self.assertRaises(HTTPError):
            transition("prepare-init", variable)
        variable.write.assert_not_called()

    @patch.dict("os.environ", {"GH_TOKEN": "test", "GITHUB_API_URL": "https://example.test",
                               "GITHUB_REPOSITORY": "owner/repo"})
    def test_live_reads_paginate_and_do_not_cache(self):
        variable = RepositoryVariable()
        variable.request = Mock(side_effect=[
            {"variables": [{"name": f"OTHER_{i}", "value": "x"} for i in range(100)]},
            {"variables": [{"name": VARIABLE, "value": "true"}]},
            {"variables": [{"name": VARIABLE, "value": "false"}]},
            {"variables": []},
        ])
        self.assertEqual(variable.read(), "true")
        self.assertEqual(variable.read(), "false")
        self.assertIsNone(variable.read())
        self.assertEqual(variable.request.call_args_list[1].args,
                         ("GET", "?per_page=100&page=2"))

    def test_write_failure_propagates(self):
        variable = self.variable("destroying")
        variable.write.side_effect = RuntimeError("API unavailable")
        with self.assertRaises(RuntimeError):
            transition("finish-destroy", variable)


if __name__ == "__main__":
    unittest.main()
