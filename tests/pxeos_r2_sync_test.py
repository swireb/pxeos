#!/usr/bin/env python3
"""用本地替身验证 R2 发布顺序和隔离。"""

import hashlib
import importlib.util
from io import BytesIO
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

from pxeos_build_version_test import job_block


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "sync-pxeos-r2.py"
ASSETS = ("arm_Image", "arm_init.cpio.gz", "bzImage", "bzImage32", "init.xz", "init_32.xz")
CONFIG = {
    "R2_ACCESS_KEY_ID": "fixture-access-id",
    "R2_SECRET_ACCESS_KEY": "fixture-access-secret",
    "R2_ENDPOINT": "https://example.r2.cloudflarestorage.com",
    "R2_BUCKET": "fixture-bucket",
    "R2_PREFIX": "downloads/kernels",
    "R2_PUBLIC_BASE_URL": "https://download.example.com/",
}


class WorkflowTests(unittest.TestCase):
    def test_r2_uses_a_separate_gated_job_after_github_release(self) -> None:
        for file, channel in (("release.yml", "latest"), ("beta.yml", "beta")):
            with self.subTest(file=file):
                workflow = (ROOT / ".github" / "workflows" / file).read_text(encoding="utf-8")
                self.assertNotIn("R2_", job_block(workflow, "release"))
                sync = job_block(workflow, "sync_r2")
                self.assertIn("needs: [release_metadata, release]", sync)
                self.assertIn("contents: read", sync)
                self.assertIn(f"group: pxeos-{channel}-r2", sync)
                self.assertIn("persist-credentials: false", sync)
                self.assertIn("--check-secrets", sync)
                self.assertLess(sync.index("--check-secrets"), sync.index("actions/download-artifact"))
                self.assertEqual(sync.count("if: steps.r2.outputs.enabled == 'true'"), 2)
                self.assertIn("pattern: distribution-files-*", sync)
                self.assertIn(f"--channel {channel}", sync)
                for name in CONFIG:
                    self.assertIn(f"{name}: ${{{{ secrets.{name} }}}}", sync)


class SyncTests(unittest.TestCase):
    def setUp(self) -> None:
        spec = importlib.util.spec_from_file_location("pxeos_r2", SCRIPT)
        self.sync = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.sync)
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.remote = self.root / "remote"
        self.remote.mkdir()
        for name in ASSETS:
            data = name.encode()
            (self.dist / name).write_bytes(data)
            checksum = hashlib.sha256(data).hexdigest()
            (self.dist / f"{name}.sha256").write_text(f"{checksum}  {name}\n", encoding="ascii")
        (self.dist / "pxeos.json").write_bytes(b"GitHub manifest fixture")
        (self.dist / "build.log").write_bytes(b"must never upload")
        self.log = self.root / "operations"
        self.output = self.root / "output"
        self.env = os.environ | CONFIG | {
            "RUNNER_TEMP": str(self.root),
            "GITHUB_OUTPUT": str(self.output),
            "FAKE_R2_REMOTE": str(self.remote),
            "FAKE_R2_LOG": str(self.log),
        }
        self.fake_rclone = self.root / "rclone"
        self.fake_rclone.write_text(
            f"#!{sys.executable}\n"
            """import os
import sys
from pathlib import Path
import shutil

action, source, destination, *flags = sys.argv[1:]
assert os.environ['RCLONE_CONFIG_R2_TYPE'] == 's3'
assert os.environ['RCLONE_CONFIG_R2_PROVIDER'] == 'Cloudflare'
assert os.environ['RCLONE_CONFIG_R2_NO_CHECK_BUCKET'] == 'true'
assert os.environ['RCLONE_CONFIG_R2_ACCESS_KEY_ID'] == 'fixture-access-id'
assert os.environ['RCLONE_CONFIG_R2_SECRET_ACCESS_KEY'] == 'fixture-access-secret'
assert not any(arg.startswith('fixture-access-') for arg in sys.argv)
assert destination.startswith('r2:fixture-bucket/')
target = Path(os.environ['FAKE_R2_REMOTE']) / destination.removeprefix('r2:fixture-bucket/')
with Path(os.environ['FAKE_R2_LOG']).open('a') as log:
    log.write(action + '\\n')
if os.environ.get('FAKE_R2_FAIL') == action:
    sys.exit(17)
if action == 'copyto':
    assert 'cache-control=no-store' in flags
    assert '--ignore-times' in flags
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    sys.exit(0)
files = Path(flags[flags.index('--files-from-raw') + 1]).read_text().splitlines()
for name in files:
    origin = Path(source) / name
    obj = target / name
    if action == 'copy':
        assert '--immutable' in flags and '--checksum' in flags
        obj.parent.mkdir(parents=True, exist_ok=True)
        if obj.exists():
            assert origin.read_bytes() == obj.read_bytes()
            continue
        shutil.copyfile(origin, obj)
    elif action == 'check':
        assert '--download' in flags and '--one-way' in flags
        assert origin.read_bytes() == obj.read_bytes()
    else:
        sys.exit(99)
""",
            encoding="utf-8",
        )
        self.fake_rclone.chmod(0o755)

    def run_sync(self, channel: str = "latest", **env: str) -> int:
        tag = "Release-261102-1234" if channel == "latest" else "Beta-261102-1234"
        with patch.dict(os.environ, self.env | env, clear=True), patch.object(
            self.sync, "install_rclone", return_value=self.fake_rclone
        ) as install:
            result = self.sync.main([
                "--input-dir", str(self.dist), "--repo", "example/pxeos", "--tag", tag,
                "--required-server-version", "1.0.1", "--channel", channel,
            ])
            self.install_called = install.called
            return result

    def test_empty_secrets_skip_without_installing_rclone(self) -> None:
        env = {"R2_ACCESS_KEY_ID": "", "R2_SECRET_ACCESS_KEY": ""}
        self.assertEqual(self.run_sync(**env), 0)
        self.assertFalse(self.install_called)
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--check-secrets"],
            env=self.env | env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "enabled=false\n")

    def test_preflight_enables_only_when_both_credentials_are_present(self) -> None:
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--check-secrets"],
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "enabled=true\n")

    def test_incomplete_config_is_an_error_before_install_or_copy(self) -> None:
        for name in CONFIG:
            with self.subTest(name=name):
                self.assertNotEqual(self.run_sync(**{name: ""}), 0)
                self.assertFalse(self.install_called)
                self.assertFalse(self.log.exists())

    def test_invalid_url_and_prefix_are_rejected_before_install(self) -> None:
        invalid = {
            "R2_ENDPOINT": ("http://example.com", "https://example.com?", "https://user@example.com"),
            "R2_PUBLIC_BASE_URL": ("https://example.com/#", "https://example.com/../x"),
            "R2_PREFIX": ("/absolute", "two//parts", "one/../two", "one/./two", "bad%2Fprefix"),
        }
        for name, values in invalid.items():
            for value in values:
                with self.subTest(name=name, value=value):
                    self.assertNotEqual(self.run_sync(**{name: value}), 0)
                    self.assertFalse(self.install_called)

    def test_versioned_allowlist_and_channel_manifest_for_both_channels(self) -> None:
        prefix = self.remote / "downloads" / "kernels"
        prior = prefix / "Prior-261101-1234" / "existing"
        prior.parent.mkdir(parents=True)
        prior.write_bytes(b"previous release")
        for channel, tag in (("latest", "Release-261102-1234"), ("beta", "Beta-261102-1234")):
            with self.subTest(channel=channel):
                self.assertEqual(self.run_sync(channel), 0)
                objects = prefix / tag
                names = {*ASSETS, *(f"{name}.sha256" for name in ASSETS), "pxeos.json"}
                self.assertEqual({obj.name for obj in objects.iterdir()}, names)
                channel_dir = prefix / channel
                self.assertEqual({obj.name for obj in channel_dir.iterdir()}, {"pxeos.json"})
                channel_manifest = (channel_dir / "pxeos.json").read_bytes()
                self.assertEqual(channel_manifest, (objects / "pxeos.json").read_bytes())
                manifest = json.loads(channel_manifest)
                self.assertEqual(manifest["requiredServerVersion"], "1.0.1")
                for item in manifest["kernels"]:
                    self.assertEqual(item["version"], tag)
                    for asset in (item["kernel"], item["initrd"]):
                        name = asset["url"].rsplit("/", 1)[1]
                        self.assertEqual(asset["url"], f"https://download.example.com/downloads/kernels/{tag}/{name}")
                        self.assertEqual(asset["sha256"], hashlib.sha256((objects / name).read_bytes()).hexdigest())
        self.assertEqual(self.log.read_text().splitlines(), ["copy", "check", "copyto"] * 2)
        self.assertEqual(prior.read_bytes(), b"previous release")
        self.assertEqual((self.dist / "pxeos.json").read_bytes(), b"GitHub manifest fixture")

    def test_retry_with_new_modification_times_preserves_history(self) -> None:
        self.assertEqual(self.run_sync(), 0)
        (self.dist / ASSETS[0]).touch()
        self.assertEqual(self.run_sync(), 0)
        self.assertEqual(self.log.read_text().splitlines(), ["copy", "check", "copyto"] * 2)

    def test_remote_failures_leave_previous_channel_manifest_in_place(self) -> None:
        manifest = self.remote / "downloads" / "kernels" / "latest" / "pxeos.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_bytes(b"previous manifest")
        for action, expected in (("copy", ["copy"]), ("check", ["copy", "check"])):
            self.assertNotEqual(self.run_sync(FAKE_R2_FAIL=action), 0)
            self.assertEqual(manifest.read_bytes(), b"previous manifest")
            self.assertEqual(self.log.read_text().splitlines(), expected)
            self.log.unlink()

    def test_invalid_checksum_blocks_upload(self) -> None:
        (self.dist / "bzImage.sha256").write_bytes(b"0" * 64 + b"  bzImage\n")
        self.assertNotEqual(self.run_sync(), 0)
        self.assertFalse(self.install_called)
        self.assertFalse(self.log.exists())

    def test_rclone_install_verifies_archive_and_extracts_only_binary(self) -> None:
        payload = BytesIO()
        with ZipFile(payload, "w") as archive:
            archive.writestr(f"{self.sync.RCLONE_PACKAGE}/rclone", b"fixture binary")
            archive.writestr("unwanted-member", b"must never extract")
        data = payload.getvalue()
        directory = self.root / "install"
        directory.mkdir()
        with patch.object(self.sync, "urlopen", return_value=BytesIO(data)):
            with self.assertRaisesRegex(ValueError, "rclone archive SHA-256 mismatch"):
                self.sync.install_rclone(directory)
        self.assertFalse((directory / "rclone").exists())

        with (
            patch.object(self.sync, "urlopen", return_value=BytesIO(data)),
            patch.object(self.sync, "RCLONE_SHA256", hashlib.sha256(data).hexdigest()),
        ):
            binary = self.sync.install_rclone(directory)
        self.assertEqual(binary.read_bytes(), b"fixture binary")
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertEqual({path.name for path in directory.iterdir()}, {binary.name, self.sync.RCLONE_PACKAGE + ".zip"})


if __name__ == "__main__":
    unittest.main()
