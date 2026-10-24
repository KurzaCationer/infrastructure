"""Run both script variants against fake tools; no credentials or cluster required."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
MOCK = r'''
import json, os, sys
tool, *args = sys.argv[1:]
with open(os.environ['MOCK_LOG'], 'a') as log:
    log.write(json.dumps([tool, *args]) + '\n')
mode = os.environ.get('MOCK_MODE', '')
if tool == 'terraform':
    if 'init' in args:
        sys.exit(1 if mode == 'init-failure' else 0)
    if mode == 'output-failure':
        print('partial output')
        sys.exit(1)
    if mode != 'empty':
        print('new-kubeconfig')
elif tool == 'gh':
    print('mock-backend-value')
    sys.exit(1 if mode == 'github-failure' else 0)
elif tool == 'kubectl':
    if 'config' in args:
        if mode == 'invalid':
            sys.exit(1)
        print('https://node.example.ts.net:6443')
    elif mode == 'unhealthy' and 'wait' in args:
        sys.exit(1)
'''


class ScriptTests:
    variant = None
    bash = None

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cluster scripts ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'kube config' / 'config.yaml'
        self.config.parent.mkdir()
        self.log = self.root / 'calls.jsonl'
        mock = self.root / 'mock.py'
        mock.write_text(MOCK)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for tool in ('terraform', 'kubectl', 'gh'):
            if self.variant == 'bat':
                wrapper = bin_dir / (tool + '.cmd')
                wrapper.write_text(
                    '@echo off\n"%MOCK_PYTHON%" "%MOCK_SCRIPT%" ' + tool + ' %*\n'
                    'exit /b %errorlevel%\n')
            else:
                wrapper = bin_dir / tool
                wrapper.write_text(
                    '#!/usr/bin/env bash\nexec "$MOCK_PYTHON" "$MOCK_SCRIPT" '
                    + tool + ' "$@"\n', newline='\n')
                wrapper.chmod(0o755)
        self.env = os.environ.copy()
        for key in ('TF_STATE_BUCKET', 'AWS_REGION', 'KUBECONFIG_PATH', 'MOCK_MODE'):
            self.env.pop(key, None)
        self.env.update(
            PATH=str(bin_dir) + os.pathsep + self.env['PATH'],
            KUBECONFIG_PATH=self.config.as_posix(),
            CLUSTER_DIR=(self.root / 'terraform cluster').as_posix(),
            TF_STATE_BUCKET='test-bucket', AWS_REGION='eu-west-1',
            MOCK_LOG=self.log.as_posix(), MOCK_SCRIPT=mock.as_posix(),
            MOCK_PYTHON=Path(sys.executable).as_posix(),
        )

    def run_script(self, name, mode=''):
        self.env['MOCK_MODE'] = mode
        script = SCRIPTS / (name + '.' + self.variant)
        command = ([os.environ['COMSPEC'], '/d', '/c', str(script)]
                   if self.variant == 'bat' else [self.bash, script.as_posix()])
        return subprocess.run(command, env=self.env, cwd=self.root,
                              capture_output=True, text=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_existing_config_never_reads_state(self):
        self.config.write_text('existing')
        result = self.run_script('check-cluster')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.config.read_text(), 'existing')
        self.assertTrue(all(call[0] == 'kubectl' for call in self.calls()))
        self.assertIn('Cluster checks passed.', result.stdout)

    def test_missing_and_empty_config_are_retrieved(self):
        for empty in (False, True):
            with self.subTest(empty=empty):
                if empty:
                    self.config.write_text('')
                result = self.run_script('check-cluster')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.config.read_text().strip(), 'new-kubeconfig')
        self.assertTrue(any(call[0] == 'terraform' for call in self.calls()))

    def test_explicit_refresh_does_not_check_cluster(self):
        self.config.write_text('existing')
        result = self.run_script('get-kubeconfig')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.config.read_text().strip(), 'new-kubeconfig')
        self.assertTrue(all('config' in call for call in self.calls() if call[0] == 'kubectl'))
        self.assertFalse(any(call[0] == 'gh' for call in self.calls()))
        if os.name != 'nt':
            self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_failed_refresh_preserves_existing_config_and_cleans_up(self):
        for mode in ('init-failure', 'output-failure', 'empty', 'invalid'):
            with self.subTest(mode=mode):
                self.config.write_text('existing')
                result = self.run_script('get-kubeconfig', mode)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.config.read_text(), 'existing')
                self.assertEqual(list(self.config.parent.iterdir()), [self.config])

    def test_failed_automatic_retrieval_stops_checks(self):
        result = self.run_script('check-cluster', 'output-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.config.exists())
        self.assertFalse(any('cluster-info' in call for call in self.calls()))

    def test_unhealthy_cluster_fails_without_refresh(self):
        self.config.write_text('existing')
        result = self.run_script('check-cluster', 'unhealthy')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Cluster checks passed.', result.stdout)
        self.assertTrue(all(call[0] == 'kubectl' for call in self.calls()))

    def test_github_fallback_and_failure(self):
        self.env.pop('TF_STATE_BUCKET')
        self.env.pop('AWS_REGION')
        result = self.run_script('get-kubeconfig')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sum(call[0] == 'gh' for call in self.calls()), 2)
        self.config.write_text('existing')
        result = self.run_script('get-kubeconfig', 'github-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.config.read_text(), 'existing')


@unittest.skipUnless(os.name == 'nt', 'Windows batch requires cmd.exe')
class BatchTests(ScriptTests, unittest.TestCase):
    variant = 'bat'


@unittest.skipUnless(os.environ.get('TEST_BASH') or (os.name != 'nt' and shutil.which('bash')),
                     'Bash required; set TEST_BASH to test Git Bash on Windows')
class BashTests(ScriptTests, unittest.TestCase):
    variant = 'sh'
    bash = os.environ.get('TEST_BASH') or shutil.which('bash')


if __name__ == '__main__':
    unittest.main()
