#!/usr/bin/env python3
"""服务端版本输入、清单和发布入口的离线契约。"""
import json
import os
import re
import textwrap
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ServerVersionBindingTests(unittest.TestCase):
    def test_generator_binds_same_version_to_history_latest_and_beta(self):
        with tempfile.TemporaryDirectory() as directory:
            dist = Path(directory)
            for name in ('bzImage', 'init.xz', 'bzImage32', 'init_32.xz', 'arm_Image', 'arm_init.cpio.gz'):
                (dist / name).write_bytes(name.encode())
            for channel in (None, 'latest', 'beta'):
                output = dist / 'pxeos.json'
                command = [sys.executable, str(ROOT / 'scripts/generate-pxeos-manifest.py'), '--input-dir', str(dist), '--repo', 'swireb/pxeos', '--tag', 'Release-261028-1200', '--required-server-version', '1.0.1', '--output', str(output), '--require-all']
                if channel:
                    command += ['--download-channel', channel]
                result = subprocess.run(command, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                document = json.loads(output.read_text())
                self.assertEqual(document['requiredServerVersion'], '1.0.1')
                self.assertEqual(len(document['kernels']), 3)

    def test_server_version_validation_matches_root_version_contract(self):
        for value in ('1.0.1', '0.0.0', '65535.65535.65535', '', 'v1.0.1', '1.0', '01.0.1', '65536.0.0', '1.0.1-beta', '1.0.1\n', '1.0.1;true'):
            result = subprocess.run(['bash', '-c', 'source ./build_version.sh; rootpxe_build_validate_server_version "$VALUE"'], cwd=ROOT, env=os.environ | {'VALUE': value}, text=True, capture_output=True)
            self.assertEqual(result.returncode == 0, value in ('1.0.1', '0.0.0', '65535.65535.65535'), value + result.stderr)

    def test_workflows_have_only_required_server_version_input_and_all_architectures(self):
        for filename in ('release.yml', 'beta.yml'):
            text = (ROOT / '.github/workflows' / filename).read_text()
            inputs = text.split('    inputs:\n', 1)[1].split('\npermissions:', 1)[0]
            self.assertIn('      server_version:', inputs)
            self.assertIn('        type: string', inputs)
            self.assertIn('        required: true', inputs)
            self.assertNotIn('default:', inputs)
            self.assertNotIn('type: boolean', text)
            self.assertNotIn('inputs.arm64', text)
            self.assertNotIn('inputs.x64', text)
            self.assertNotIn('inputs.x86', text)
            self.assertIn('PXEOS_REQUIRED_SERVER_VERSION: ${{ needs.release_metadata.outputs.server_version }}', text)
            for line in text.splitlines():
                if 'generate-pxeos-manifest.py' in line:
                    self.assertIn('--required-server-version "$PXEOS_REQUIRED_SERVER_VERSION"', line)
                    self.assertIn('--require-all', line)
            self.assertIn('- 内核版本（PXEOS）：${{ env.TAG_NAME }}', text)
            self.assertIn('- 对应服务端版本：${{ env.PXEOS_REQUIRED_SERVER_VERSION }}（必须完全一致）', text)

    def test_noninteractive_build_refuses_missing_or_invalid_version_before_dependencies(self):
        build = (ROOT / 'build.sh').read_text()
        prefix = build.split('if ! checkDependencies;', 1)[0]
        import shlex
        prefix = re.sub(r'^PROJECT_DIRECTORY=.*$', 'PROJECT_DIRECTORY=' + shlex.quote(str(ROOT)), prefix, count=1, flags=re.M)
        with tempfile.TemporaryDirectory() as directory:
            startup = Path(directory) / 'startup.sh'
            startup.write_text(prefix + '\nprintf "dependencies would run\\n"\n')
            for value in (None, '', '1.0.1-beta', '01.0.1', '65536.0.0', '1.0.1'):
                env = os.environ.copy()
                env.pop('PXEOS_REQUIRED_SERVER_VERSION', None)
                env['PXEOS_BUILD_VERSION'] = 'Local-261028-1200'
                if value is not None:
                    env['PXEOS_REQUIRED_SERVER_VERSION'] = value
                result = subprocess.run(['bash', str(startup), '-nka', 'x64'], env=env, stdin=subprocess.DEVNULL, text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, value == '1.0.1', str(value) + result.stderr)
                self.assertEqual('dependencies would run' in result.stdout, value == '1.0.1')
            result = subprocess.run(['bash', str(startup), '--server-version', '1.0.1', '-nka', 'x64'], env=env | {'PXEOS_REQUIRED_SERVER_VERSION': ''}, stdin=subprocess.DEVNULL, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(['bash', str(startup), '--fs-download-only'], env=env | {'PXEOS_REQUIRED_SERVER_VERSION': ''}, stdin=subprocess.DEVNULL, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_metadata_refuses_invalid_input_before_remote_lookup_and_shell_evaluation(self):
        for filename in ('release.yml', 'beta.yml'):
            workflow = (ROOT / '.github/workflows' / filename).read_text()
            metadata = workflow.split('  release_metadata:\n', 1)[1].split('  download_filesystem_packages:', 1)[0]
            body = textwrap.dedent(metadata.split('        run: |\n', 1)[1])
            with tempfile.TemporaryDirectory() as directory:
                marker = Path(directory) / 'injected'
                output = Path(directory) / 'outputs'
                for value in ('', 'v1.0.1', '1.0.1\n', '01.0.1', '65536.0.0', f'$(touch {marker})'):
                    result = subprocess.run(['bash', '-c', body], cwd=ROOT, text=True, capture_output=True, env=os.environ | {'PXEOS_REQUIRED_SERVER_VERSION': value, 'GITHUB_OUTPUT': str(output)})
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(output.exists(), 'invalid input emitted metadata')
                    self.assertFalse(marker.exists(), 'input was evaluated as shell')

    def test_generator_rejects_missing_and_invalid_binding_without_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'pxeos.json'
            base = [sys.executable, str(ROOT / 'scripts/generate-pxeos-manifest.py'), '--input-dir', directory, '--repo', 'swireb/pxeos', '--tag', 'Release-261028-1200', '--output', str(output)]
            for value in (None, '', '1.0.1-beta', '01.0.1', '65536.0.0', '1.0.1\n'):
                result = subprocess.run(base + ([] if value is None else ['--required-server-version', value]), text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())

    def test_server_version_option_missing_argument_fails(self):
        result = subprocess.run(['bash', str(ROOT / 'build.sh'), '--server-version'], cwd=ROOT, stdin=subprocess.DEVNULL, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_interactive_version_prompt_obeys_noconfirm(self):
        try:
            import pty
        except ImportError:
            self.skipTest('当前平台不提供PTY')
        import shlex
        build = (ROOT / 'build.sh').read_text()
        prefix = build.split('if ! checkDependencies;', 1)[0]
        prefix = re.sub(r'^PROJECT_DIRECTORY=.*$', 'PROJECT_DIRECTORY=' + shlex.quote(str(ROOT)), prefix, count=1, flags=re.M)
        with tempfile.TemporaryDirectory() as directory:
            startup = Path(directory) / 'startup.sh'
            startup.write_text(prefix + '\nprintf "dependencies would run\\n"\n')
            for noconfirm in (True, False):
                master, slave = pty.openpty()
                env = os.environ.copy()
                env.pop('PXEOS_REQUIRED_SERVER_VERSION', None)
                env.pop('GITHUB_ACTIONS', None)
                env['PXEOS_BUILD_VERSION'] = 'Local-261028-1200'
                process = subprocess.Popen(['bash', str(startup), *(['-n'] if noconfirm else [])], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
                os.close(slave)
                try:
                    if not noconfirm:
                        os.write(master, b'1.0.1\n')
                    try:
                        stdout, stderr = process.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
                        self.fail('-n不应等待终端输入')
                    self.assertEqual(process.returncode == 0, not noconfirm, stdout + stderr)
                    self.assertEqual('dependencies would run' in stdout, not noconfirm)
                finally:
                    os.close(master)

if __name__ == '__main__':
    unittest.main()
