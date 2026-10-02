#!/usr/bin/env python3
"""离线覆盖 PXEOS 发布清单与固定发布频道。"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
import sys


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts" / "generate-pxeos-manifest.py"
PUBLISHER = ROOT / "scripts" / "publish-channel.sh"
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"


def git_bash_path(path: Path) -> str:
    if os.name != "nt" or not path.drive:
        return str(path)
    return "/" + path.drive[0].lower() + path.as_posix()[2:]


class ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.dist = Path(self.tempdir.name) / "dist"
        self.dist.mkdir()

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def write_pair(self, kernel: str, initrd: str) -> None:
        (self.dist / kernel).write_bytes((kernel + "\\n").encode())
        (self.dist / initrd).write_bytes((initrd + "\\n").encode())

    def generate(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--input-dir",
                str(self.dist),
                "--repo",
                "swireb/pxeos",
                "--tag",
                "v1.2.3",
                "--download-channel",
                "latest",
                "--output",
                str(self.dist / "pxeos.json"),
                *extra,
            ],
            text=True,
            capture_output=True,
        )

    def test_complete_release_has_three_architectures_real_urls_and_hashes(self) -> None:
        self.write_pair("bzImage32", "init_32.xz")
        self.write_pair("bzImage", "init.xz")
        self.write_pair("arm_Image", "arm_init.cpio.gz")

        result = self.generate("--require-all")

        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.dist / "pxeos.json").read_text())
        self.assertEqual(set(manifest), {"kernels"})
        self.assertEqual([entry["arch"] for entry in manifest["kernels"]], ["x86", "x64", "arm64"])
        self.assertEqual({entry["version"] for entry in manifest["kernels"]}, {"v1.2.3"})
        for entry in manifest["kernels"]:
            self.assertEqual(set(entry), {"arch", "version", "kernel", "initrd"})
            for role in ("kernel", "initrd"):
                name = entry[role]["url"].rsplit("/", 1)[1]
                self.assertEqual(
                    entry[role]["url"],
                    f"https://github.com/swireb/pxeos/releases/download/latest/{name}",
                )
                self.assertEqual(
                    entry[role]["sha256"],
                    hashlib.sha256((self.dist / name).read_bytes()).hexdigest(),
                )

    def test_partial_build_only_emits_complete_pairs(self) -> None:
        self.write_pair("bzImage", "init.xz")
        (self.dist / "bzImage32").write_bytes(b"kernel without initrd")

        result = self.generate()

        self.assertEqual(result.returncode, 0, result.stderr)
        kernels = json.loads((self.dist / "pxeos.json").read_text())["kernels"]
        self.assertEqual([entry["arch"] for entry in kernels], ["x64"])

    def test_empty_build_emits_an_empty_manifest_for_partial_beta_publication(self) -> None:
        result = self.generate()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads((self.dist / "pxeos.json").read_text()), {"kernels": []}
        )

    def test_require_all_rejects_partial_build(self) -> None:
        self.write_pair("bzImage", "init.xz")

        result = self.generate("--require-all")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.dist / "pxeos.json").exists())

    def test_mutable_alias_is_not_a_valid_historical_tag(self) -> None:
        self.write_pair("bzImage", "init.xz")
        result = subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--input-dir",
                str(self.dist),
                "--repo",
                "swireb/pxeos",
                "--tag",
                "latest",
                "--download-channel",
                "latest",
                "--output",
                str(self.dist / "pxeos.json"),
            ],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.dist / "pxeos.json").exists())


class PublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tempdir.name)
        self.bin_dir = self.workdir / "bin"
        self.bin_dir.mkdir()
        self.log = self.workdir / "gh.log"
        self.state = self.workdir / "gh.state"
        self.manifest = self.workdir / "pxeos.json"
        assets = {"x86": ("bzImage32", "init_32.xz"), "x64": ("bzImage", "init.xz"), "arm64": ("arm_Image", "arm_init.cpio.gz")}
        kernels = []
        for arch, names in assets.items():
            record = {"arch": arch, "version": "v1.2.3"}
            for role, name in zip(("kernel", "initrd"), names):
                data = name.encode()
                (self.workdir / name).write_bytes(data)
                (self.workdir / f"{name}.sha256").write_bytes(f"{hashlib.sha256(data).hexdigest()}  {name}\n".encode())
                record[role] = {"url": f"https://github.com/swireb/pxeos/releases/download/latest/{name}", "sha256": hashlib.sha256(data).hexdigest()}
            kernels.append(record)
        self.manifest.write_text(json.dumps({"kernels": kernels}) + "\n")
        fake_gh = self.bin_dir / "gh"
        fake_gh.write_text(
            "#!/usr/bin/env bash\nset -eu\n"
            "printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n"
            "if [[ \"${1-}\" == release && \"${2-}\" == upload ]]; then\n"
            "  asset_name=\"${4##*#}\"\n"
            "  asset_name=\"${asset_name##*/}\"\n"
            "  printf 'UPLOAD %s %s\\n' \"$asset_name\" \"$*\" >> \"$GH_LOG\"\n"
            "  if [[ \"${GH_UPLOAD_FAIL:-}\" == \"$asset_name\" ]]; then exit 7; fi\n"
            "  exit 0\n"
            "fi\n"
            "ref_state=\"${GH_REF_STATE:-missing}\"\n"
            "release_state=\"${GH_RELEASE_STATE:-missing}\"\n"
            "if [[ -f \"$GH_STATE_FILE\" ]]; then source \"$GH_STATE_FILE\"; fi\n"
            "case \"$*\" in\n"
            "  *'git/ref/tags/'*)\n"
            "    if [[ \"$ref_state\" == missing ]]; then echo 'HTTP 404 Not Found' >&2; exit 1; fi\n"
            "    if [[ \"$ref_state\" == forbidden ]]; then echo 'HTTP 403 Forbidden' >&2; exit 1; fi\n"
            "    echo '{\"ref\":\"refs/tags/channel\"}'\n"
            "    ;;\n"
            "  *'releases/tags/'*)\n"
            "    if [[ \"$release_state\" == missing ]]; then echo 'HTTP 404 Not Found' >&2; exit 1; fi\n"
            "    if [[ \"$release_state\" == forbidden ]]; then echo 'HTTP 403 Forbidden' >&2; exit 1; fi\n"
            "    if [[ \"$release_state\" == immutable ]]; then echo 123:true; else echo 123:false; fi\n"
            "    ;;\n"
            "esac\n"
            "if [[ \"$*\" == *'--method POST repos/'*'git/refs'* ]]; then echo 'ref_state=exists' > \"$GH_STATE_FILE\"; fi\n"
            "if [[ \"$*\" == *'--method POST repos/'*'releases'* ]]; then echo 'ref_state=exists' > \"$GH_STATE_FILE\"; echo 'release_state=exists' >> \"$GH_STATE_FILE\"; fi\n"
            "if [[ \"$*\" == *'--method PATCH repos/'*'git/refs'* ]]; then echo 'ref_state=exists' > \"$GH_STATE_FILE\"; fi\n"
            "if [[ \"$*\" == *'--method PATCH repos/'*'releases/'* ]]; then echo 'ref_state=exists' > \"$GH_STATE_FILE\"; echo 'release_state=exists' >> \"$GH_STATE_FILE\"; fi\n"
        )
        fake_gh.chmod(0o755)
        fake_python = self.bin_dir / "python3"
        python_executable = shlex.quote(git_bash_path(Path(sys.executable)))
        fake_python.write_text(f"#!/usr/bin/env bash\nexec {python_executable} \"$@\"\n")
        fake_python.chmod(0o755)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def publish(self, channel: str, **environment: str) -> subprocess.CompletedProcess[str]:
        if channel == "beta":
            self.manifest.write_text(self.manifest.read_text().replace("/latest/", "/beta/"))
        env = os.environ | {
            "PATH": git_bash_path(self.bin_dir) + ":/usr/bin",
            "GH_BIN": git_bash_path(self.bin_dir / "gh"),
            "GH_LOG": git_bash_path(self.log),
            "GH_STATE_FILE": git_bash_path(self.state),
            "GH_REF_STATE": "missing",
            "GH_RELEASE_STATE": "missing",
            **environment,
        }
        return subprocess.run(
            [
                BASH,
                git_bash_path(PUBLISHER),
                "--repo",
                "swireb/pxeos",
                "--channel",
                channel,
                "--target",
                "a" * 40,
                "--manifest",
                git_bash_path(self.manifest),
                "--resource-dir",
                git_bash_path(self.workdir),
            ],
            text=True,
            capture_output=True,
            env=env,
        )

    def test_first_publish_creates_only_requested_alias_and_correct_release(self) -> None:
        result = self.publish("latest")

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertIn("POST repos/swireb/pxeos/git/refs", log)
        self.assertIn("ref=refs/tags/latest", log)
        self.assertNotIn("refs/tags/beta", log)
        self.assertIn("POST repos/swireb/pxeos/releases", log)
        self.assertIn("name=Latest Release", log)
        self.assertIn("prerelease=false", log)
        self.assertIn("make_latest=true", log)

    def test_existing_publish_updates_requested_ref_and_is_idempotent(self) -> None:
        result = self.publish("beta", GH_REF_STATE="exists", GH_RELEASE_STATE="exists")

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertIn("PATCH repos/swireb/pxeos/git/refs/tags/beta", log)
        self.assertIn("force=true", log)
        self.assertIn("PATCH repos/swireb/pxeos/releases/123", log)
        self.assertIn("name=Latest Beta", log)
        self.assertIn("prerelease=true", log)
        self.assertIn("make_latest=false", log)

    def test_ref_api_failure_does_not_call_mutating_alias_commands(self) -> None:
        result = self.publish("latest", GH_REF_STATE="forbidden")

        self.assertNotEqual(result.returncode, 0)
        log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertNotIn("POST repos/swireb/pxeos/git/refs", log)
        self.assertNotIn("PATCH repos/swireb/pxeos/git/refs", log)

    def test_empty_manifest_skips_alias_publish(self) -> None:
        self.manifest.write_text('{"kernels": []}\n')
        result = self.publish("beta")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_manifest_name_is_shared_but_channel_urls_and_tags_remain_distinct(self) -> None:
        latest = self.publish("latest")
        beta = self.publish("beta")

        self.assertEqual(latest.returncode, 0, latest.stderr)
        self.assertEqual(beta.returncode, 0, beta.stderr)
        uploads = self.log.read_text(encoding="utf-8")
        self.assertIn("release upload latest", uploads)
        self.assertIn("release upload beta", uploads)
        self.assertGreaterEqual(uploads.count("pxeos.json --clobber --repo swireb/pxeos"), 2)

    def test_legacy_channel_specific_manifest_name_is_rejected(self) -> None:
        legacy = self.workdir / "pxeos-latest.json"
        self.manifest.rename(legacy)
        self.manifest = legacy

        result = self.publish("latest")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_invalid_manifest_does_not_call_alias_api(self) -> None:
        self.manifest.write_text('{"kernels": "not-a-list"}\n')

        result = self.publish("latest")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_checksum_must_be_one_line_for_the_same_asset(self) -> None:
        digest = hashlib.sha256(b"bzImage32").hexdigest()
        (self.workdir / "bzImage32.sha256").write_text(
            f"{digest}  other-file\n{digest}  bzImage32\n"
        )

        result = self.publish("latest")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_bad_checksum_has_zero_api_calls(self) -> None:
        (self.workdir / "bzImage32.sha256").write_text(
            f"{'0' * 64}  bzImage32\n"
        )

        result = self.publish("latest")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_bad_url_or_missing_resource_does_not_call_alias_api(self) -> None:
        document = json.loads(self.manifest.read_text())
        document["kernels"][0]["kernel"]["url"] = "https://example.invalid/not-a-channel"
        self.manifest.write_text(json.dumps(document) + "\n")
        result = self.publish("latest")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

        document["kernels"][0]["kernel"]["url"] = (
            "https://github.com/swireb/pxeos/releases/download/latest/bzImage32"
        )
        self.manifest.write_text(json.dumps(document) + "\n")
        (self.workdir / "bzImage32").unlink()
        result = self.publish("latest")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_dangling_resource_symlink_is_rejected(self) -> None:
        dangling = self.workdir / "unused-resource"
        try:
            dangling.symlink_to(self.workdir / "missing-resource")
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"symlink creation unavailable: {error}")
        (self.workdir / "bzImage32").unlink()
        (self.workdir / "bzImage32.sha256").unlink()
        (self.workdir / "bzImage32").symlink_to(self.workdir / "missing-resource")

        result = self.publish("latest")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_latest_requires_all_three_complete_pairs(self) -> None:
        document = json.loads(self.manifest.read_text())
        document["kernels"] = document["kernels"][:2]
        self.manifest.write_text(json.dumps(document) + "\n")

        result = self.publish("latest")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_two_latest_publishes_clobber_every_asset_and_manifest_last(self) -> None:
        first = self.publish("latest")
        second = self.publish("latest")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        uploads = [
            line for line in self.log.read_text(encoding="utf-8").splitlines() if line.startswith("UPLOAD ")
        ]
        self.assertEqual(len(uploads), 14)
        self.assertTrue(all("--clobber" in line for line in uploads))
        self.assertTrue(uploads[6].endswith("pxeos.json --clobber --repo swireb/pxeos"))
        self.assertTrue(uploads[13].endswith("pxeos.json --clobber --repo swireb/pxeos"))

    def test_first_resource_upload_failure_does_not_upload_manifest(self) -> None:
        result = self.publish("latest", GH_UPLOAD_FAIL="bzImage32")

        self.assertNotEqual(result.returncode, 0)
        uploads = [
            line for line in self.log.read_text(encoding="utf-8").splitlines() if line.startswith("UPLOAD ")
        ]
        self.assertTrue(uploads)
        self.assertNotIn("pxeos.json", "\n".join(uploads))

    def test_immutable_release_and_forbidden_release_have_zero_writes(self) -> None:
        for release_state in ("immutable", "forbidden"):
            with self.subTest(release_state=release_state):
                result = self.publish("latest", GH_REF_STATE="exists", GH_RELEASE_STATE=release_state)
                self.assertNotEqual(result.returncode, 0)
                log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
                self.assertNotRegex(log, r"(POST|PATCH|UPLOAD)")

    def test_beta_x64_pair_only_publishes_pair_and_empty_skips(self) -> None:
        for name in ("bzImage32", "init_32.xz", "arm_Image", "arm_init.cpio.gz"):
            (self.workdir / name).unlink()
            (self.workdir / f"{name}.sha256").unlink()
        document = json.loads(self.manifest.read_text())
        document["kernels"] = [entry for entry in document["kernels"] if entry["arch"] == "x64"]
        self.manifest.write_text(
            json.dumps(document).replace("/latest/", "/beta/") + "\n"
        )

        result = self.publish("beta")

        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = self.log.read_text(encoding="utf-8").splitlines()
        self.assertIn("UPLOAD bzImage", "\n".join(uploads))
        self.assertIn("UPLOAD init.xz", "\n".join(uploads))
        self.assertTrue(uploads[-1].endswith("pxeos.json --clobber --repo swireb/pxeos"))
        self.assertNotIn("bzImage32", "\n".join(uploads))
        self.assertNotIn("arm_Image", "\n".join(uploads))

        self.log.unlink()
        self.manifest.write_text('{"kernels": []}\n')
        empty = self.publish("beta")
        self.assertEqual(empty.returncode, 0, empty.stderr)
        self.assertFalse(self.log.exists())

    def test_check_release_tag_existing_ref_or_release_has_zero_writes(self) -> None:
        checker = ROOT / "scripts" / "check-release-tag.sh"
        for ref_state, release_state in (("exists", "missing"), ("missing", "exists")):
            with self.subTest(ref_state=ref_state, release_state=release_state):
                env = os.environ | {
                    "PATH": git_bash_path(self.bin_dir) + ":/usr/bin",
                    "GH_BIN": git_bash_path(self.bin_dir / "gh"),
                    "GH_LOG": git_bash_path(self.log),
                    "GH_STATE_FILE": git_bash_path(self.state),
                    "GH_REF_STATE": ref_state,
                    "GH_RELEASE_STATE": release_state,
                }
                result = subprocess.run(
                    [
                        BASH,
                        git_bash_path(checker),
                        "--repo",
                        "swireb/pxeos",
                        "--tag",
                        "v1.2.3",
                    ],
                    text=True,
                    capture_output=True,
                    env=env,
                )
                self.assertNotEqual(result.returncode, 0)
                log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
                self.assertNotRegex(log, r"(POST|PATCH|UPLOAD)")
                self.log.unlink(missing_ok=True)


class WorkflowContractTests(unittest.TestCase):
    def test_workflows_generate_channel_specific_manifests_after_history_release(self) -> None:
        for workflow, manifest, channel in (
            ("release.yml", "pxeos.json", "latest"),
            ("beta.yml", "pxeos.json", "beta"),
        ):
            text = (ROOT / ".github" / "workflows" / workflow).read_text(encoding="utf-8")
            self.assertIn(manifest, text)
            self.assertIn(f"--channel {channel}", text)
            self.assertLess(text.index("Create GitHub Release") if workflow == "release.yml" else text.index("Create release"), text.index(f"--channel {channel}"))
            self.assertIn("contents: write", text)

    def test_release_workflow_contract_keeps_generator_history_then_publisher(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        beta = (ROOT / ".github" / "workflows" / "beta.yml").read_text(encoding="utf-8")
        self.assertLess(
            release.index("Validate historical release tag"),
            release.index("Generate latest download manifest"),
        )
        self.assertLess(
            release.index("Create GitHub Release"),
            release.index("Publish latest download manifest"),
        )
        self.assertIn("--require-all", release)
        self.assertNotIn("--require-all", beta)
        for text in (release, beta):
            self.assertIn("GITHUB_RUN_ID", text)
            self.assertIn("GITHUB_RUN_ATTEMPT", text)
        self.assertIn("group: pxeos-latest-release", release)
        self.assertIn("group: pxeos-beta-release", beta)
        self.assertRegex(release, r"permissions:\s+contents:\s+read")
        self.assertIn("permissions:\n      contents: write", release)
        self.assertIn("target_commitish: ${{ github.sha }}", release)
        self.assertIn('--target "$GITHUB_SHA"', release)

        try:
            import yaml
        except ImportError:
            yaml = None
        if yaml is not None:
            parsed = yaml.safe_load(release)
            if True in parsed and "on" not in parsed:
                parsed["on"] = parsed.pop(True)
            self.assertEqual(parsed["permissions"]["contents"], "read")
            self.assertEqual(parsed["jobs"]["release"]["permissions"]["contents"], "write")
            self.assertEqual(
                parsed["jobs"]["release"]["concurrency"]["group"],
                "pxeos-latest-release",
            )

    def test_beta_architecture_inputs_validate_and_gate_complete_pairs(self) -> None:
        beta = (ROOT / ".github" / "workflows" / "beta.yml").read_text(encoding="utf-8")
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML is unavailable")
        document = yaml.safe_load(beta)
        if True in document and "on" not in document:
            document["on"] = document.pop(True)

        inputs = document["on"]["workflow_dispatch"]["inputs"]
        self.assertEqual(set(inputs), {"arm64", "x64", "x86"})
        for arch in inputs:
            self.assertEqual(inputs[arch], {"type": "boolean", "default": True, "required": False, "description": arch})

        validation = document["jobs"]["input_checks"]["steps"][0]["run"]
        for values, expected in (
            (("false", "false", "false"), False),
            (("true", "false", "false"), True),
            (("true", "false", "true"), True),
            (("true", "true", "true"), True),
        ):
            with self.subTest(values=values):
                result = subprocess.run(
                    [BASH, "-c", validation],
                    text=True,
                    capture_output=True,
                    env=os.environ | dict(zip(("ARM64", "X64", "X86"), values)),
                )
                self.assertEqual(result.returncode == 0, expected, result.stderr)

        jobs = document["jobs"]
        self.assertEqual(jobs["download_filesystem_packages"]["if"], "${{ inputs.arm64 || inputs.x64 || inputs.x86 }}")
        for arch in ("arm64", "x64", "x86"):
            self.assertEqual(jobs[f"build_kernel_{arch}"]["if"], f"${{{{ inputs.{arch} }}}}")
            self.assertEqual(jobs[f"build_initrd_{arch}"]["if"], f"${{{{ inputs.{arch} }}}}")
            self.assertIn("download_filesystem_packages", jobs[f"build_initrd_{arch}"]["needs"])
        self.assertIn("input_checks", jobs["release"]["needs"])
        self.assertIn("download_filesystem_packages", jobs["release"]["needs"])
        self.assertNotIn("publish_beta", beta)


if __name__ == "__main__":
    unittest.main()
