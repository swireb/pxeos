"""在临时目录编译和运行原生存储 helper 离线回归。"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

import pxeos_storage_read_benchmark as benchmark


class StorageHelperFixture(unittest.TestCase):
    def test_benchmark_reaps_worker_group_when_the_shell_exits_first(self):
        worker = 'sleep 3 & printf "%s\\n" "$!" >child.pid; exit 7'
        with tempfile.TemporaryDirectory(prefix='rootpxe-benchmark-cleanup-') as directory:
            path = Path(directory)
            original = benchmark.WORKER
            try:
                benchmark.WORKER = worker
                with self.assertRaisesRegex(RuntimeError, 'first worker exits'):
                    benchmark.run_case('old', 'unused', 'unused', [('unused', 1, '')], 1, path,
                                       timeout=2)
            finally:
                benchmark.WORKER = original

            child = Path('/proc') / (path / '0/child.pid').read_text().strip() / 'stat'
            deadline = time.monotonic() + 2
            while True:
                try:
                    state = child.read_text().rsplit(')', 1)[1].split()[0]
                except FileNotFoundError:
                    break
                if state == 'Z':
                    break
                self.assertLess(time.monotonic(), deadline, 'benchmark left a worker running')
                time.sleep(0.01)

    def run_filesystem_fixture(self, *args):
        root = Path(__file__).resolve().parents[1]
        source = root / 'Buildroot/package/rootpxe-storage-io/src'
        flags = shlex.split(subprocess.check_output(
            [os.environ.get('PKG_CONFIG', 'pkg-config'), '--cflags', '--libs', 'json-c', 'openssl'], text=True))
        with tempfile.TemporaryDirectory(prefix='rootpxe-storage-fs-fixture-') as directory:
            binary = Path(directory) / 'fixture'
            subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_GNU_SOURCE',
                            '-D_FILE_OFFSET_BITS=64', '-I', str(source),
                            str(root / 'tests/storage_fs_fixture.c'),
                            str(source / 'storage_context.c'), str(source / 'storage_fs.c'),
                            '-DROOTPXE_TEST_STATX_RACE', '-Wl,--wrap=statx',
                            '-Wl,--wrap=posix_fadvise64',
                            '-Wl,--wrap=EVP_MD_CTX_new', '-Wl,--wrap=EVP_DigestUpdate',
                            *flags, '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), *args], check=True, timeout=60, cwd=directory,
                                    text=True, stdout=subprocess.PIPE)
            fixture_directories = result.stdout.splitlines()
            self.assertTrue(fixture_directories, 'filesystem fixture did not report its work directory')
            for fixture_directory in fixture_directories:
                path = Path(directory, fixture_directory).resolve()
                self.assertEqual(path.parent, Path(directory).resolve())
                self.assertFalse(path.exists(), f'filesystem fixture left {path}')

    def test_actual_filesystem_receipts_and_bounded_streams(self):
        # Includes an unbounded stream larger than 200 MiB, with temporary files only.
        self.run_filesystem_fixture()

    def test_read_backpressure_preserves_full_stream_but_rejects_closed_and_short_streams(self):
        self.run_filesystem_fixture('read')

    def test_read_progress_follows_elapsed_time(self):
        self.run_filesystem_fixture('progress')

    def test_read_binds_stream_length_to_the_original_intent_proof(self):
        self.run_filesystem_fixture('read-proof')

    def test_read_continues_when_sequential_hint_is_unsupported(self):
        self.run_filesystem_fixture('read-hint')

    def test_read_omits_payload_digest_only_for_explicit_deploy_requests(self):
        self.run_filesystem_fixture('read-digest')

    def test_parsers_and_identity_syscall_order(self):
        root = Path(__file__).resolve().parents[1]
        source = root / 'Buildroot/package/rootpxe-storage-io/src'
        wrapped = ('prctl', 'setgroups', 'setresgid', 'setresuid', 'getresgid',
                   'getresuid', 'setfsuid', 'setfsgid', 'getgroups', 'getppid', 'kill', 'syscall', 'mount')
        # All privilege-affecting calls are linker stubs; no UID change, NAS,
        # mount, block device, credential or real task state is involved.
        flags = shlex.split(subprocess.check_output(
            [os.environ.get('PKG_CONFIG', 'pkg-config'), '--cflags', '--libs', 'json-c', 'openssl'], text=True))
        with tempfile.TemporaryDirectory(prefix='rootpxe-storage-fixture-') as directory:
            binary = Path(directory) / 'fixture'
            subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_GNU_SOURCE',
                            '-D_FILE_OFFSET_BITS=64', '-I', str(source),
                            str(root / 'tests/storage_helper_fixture.c'),
                            str(source / 'storage_context.c'), str(source / 'storage_mount.c'),
                            *['-Wl,--wrap=' + name for name in wrapped], *flags, '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=60, cwd=directory)


if __name__ == '__main__':
    unittest.main()
