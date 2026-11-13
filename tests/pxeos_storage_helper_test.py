"""在临时目录编译和运行原生存储 helper 离线回归。"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class StorageHelperFixture(unittest.TestCase):
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
                            *flags, '-o', str(binary)], check=True)
            subprocess.run([str(binary), *args], check=True, timeout=60, cwd=directory)

    def test_actual_filesystem_receipts_and_bounded_streams(self):
        # Includes an unbounded stream larger than 200 MiB, with temporary files only.
        self.run_filesystem_fixture()

    def test_read_backpressure_preserves_full_stream_but_rejects_closed_and_short_streams(self):
        self.run_filesystem_fixture('read')

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
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
