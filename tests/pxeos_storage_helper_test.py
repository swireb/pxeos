"""用户自行运行的离线 fixture；本轮仅新增源码，未执行。"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class StorageHelperFixture(unittest.TestCase):
    def test_actual_filesystem_receipts_and_bounded_streams(self):
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
            # Includes one 200 MiB split boundary. All bytes stay in this local
            # temporary fixture; no production path or mount entry is opened.
            subprocess.run([str(binary)], check=True)

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
