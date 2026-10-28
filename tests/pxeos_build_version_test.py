#!/usr/bin/env python3
"""离线核对一次选号、CI 传播、镜像写号与运行时版本显示。"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "build_version.sh"
OVERLAY = ROOT / "Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
FUNCS = OVERLAY / "usr/share/pxeos/lib/funcs.sh"
NETWORK = OVERLAY / "etc/init.d/S40network"
GENERATOR = ROOT / "scripts/generate-pxeos-manifest.py"
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"
# Git Bash 在 Windows 上不保证附带 IANA tzdata；fixture 模拟北京时间转换，
# 同时记录生产函数传入的 TZ。实际 CI 的 Ubuntu 时区支持不由该 mock 证明。
SHANGHAI_CLOCK = (
    'date() { printf "%s\\n" "$TZ" >> "$DATE_LOG"; '
    'if [[ $TZ == Asia/Shanghai ]]; then '
    'TZ=UTC command date --date="2026-10-13 17:01:00 UTC +8 hours" "$@"; '
    'else TZ=UTC command date --date="2026-10-13 17:01:00 UTC" "$@"; fi; }\n'
)


def bash_path(path: Path) -> str:
    if os.name != "nt" or not path.drive:
        return str(path)
    return "/" + path.drive[0].lower() + path.as_posix()[2:]


def job_block(workflow: str, job: str) -> str:
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z_][A-Za-z0-9_]*:|\Z)", workflow, re.M | re.S)
    if match is None:
        raise AssertionError(f"缺少 workflow job: {job}")
    return match.group(1)


def step_run(job: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    if marker not in job:
        raise AssertionError(f"缺少 workflow step: {name}")
    step = job.split(marker, 1)[1].split("      - name:", 1)[0]
    run = step.split("        run: |\n", 1)[1]
    return textwrap.dedent(run).rstrip() + "\n"


def shell_function(text: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}\(\) \{{\n.*?^\}}\n", text, re.M | re.S)
    if match is None:
        raise AssertionError(f"缺少 Shell 函数: {name}")
    return match.group(0)


class BuildVersionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tempdir.name)
        self.date_log = self.workdir / "date.log"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_shell(self, body: str, **values: str | None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.pop("PXEOS_BUILD_VERSION", None)
        env.pop("GITHUB_ACTIONS", None)
        env["DATE_LOG"] = bash_path(self.date_log)
        for key, value in values.items():
            if value is not None:
                env[key] = value
        return subprocess.run(
            [BASH, "-c", "set -euo pipefail\n" + body],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            encoding="utf-8",
        )

    def resolve(self, **values: str | None) -> subprocess.CompletedProcess[str]:
        return self.run_shell(
            f"source {shlex.quote(bash_path(HELPER))}\n"
            'date() { printf called >> "$DATE_LOG"; return 99; }\n'
            "rootpxe_build_resolve_version\n"
            'printf "%s\\n" "$PXEOS_BUILD_VERSION"\n',
            **values,
        )

    def test_explicit_release_beta_and_local_versions_preserve_the_complete_token(self) -> None:
        for version in (
            "Release-261014-0101", "Beta-261014-0101", "Local-261014-0101",
            "Release-261014-0101-1234567890-2", "Beta-261014-0101-2345678901-3",
        ):
            with self.subTest(version=version):
                result = self.resolve(PXEOS_BUILD_VERSION=version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, version + "\n")
        self.assertFalse(self.date_log.exists(), "显式版本不应再次采样时间")

    def test_github_actions_requires_a_release_or_beta_canonical_version(self) -> None:
        for version in (None, "", "Local-261014-0101", "19800101", "latest", "beta"):
            with self.subTest(version=version):
                result = self.resolve(GITHUB_ACTIONS="true", PXEOS_BUILD_VERSION=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("PXEOS_BUILD_VERSION", result.stderr)
                self.assertEqual(result.stdout, "")
        for version in ("Release-261014-0101-1234-2", "Beta-261014-0101"):
            result = self.resolve(GITHUB_ACTIONS="true", PXEOS_BUILD_VERSION=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, version + "\n")
        self.assertFalse(self.date_log.exists(), "CI 不得生成本地号")

    def test_invalid_values_fail_without_time_sampling_or_shell_evaluation(self) -> None:
        marker = self.workdir / "injected"
        for version in (
            "", "Release-261014-0101 ", " Release-261014-0101", "Release-261014-0101\n",
            "Release-261014-0101\nexport injected=yes", "Release-261014-0101\r",
            "Beta-261014-0101\t", "Release-261014-0101-abc-2", "Release-261014-0101-1234",
            "Release-261399-9999", "Release-261014-0101-" + "1" * 65 + "-1",
            f"Release-261014-0101$(touch {bash_path(marker)})", "Release-261014-0101;true",
            "unbuilt", "20261014",
        ):
            with self.subTest(version=version):
                result = self.resolve(PXEOS_BUILD_VERSION=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("PXEOS_BUILD_VERSION", result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse(self.date_log.exists())

    def test_local_version_uses_shanghai_once_across_timezone_and_day_boundaries(self) -> None:
        for timezone in ("UTC", "America/New_York", "Asia/Tokyo"):
            with self.subTest(timezone=timezone):
                self.date_log.unlink(missing_ok=True)
                result = self.run_shell(
                    f"source {shlex.quote(bash_path(HELPER))}\n"
                    + SHANGHAI_CLOCK
                    + "rootpxe_build_resolve_version\nrootpxe_build_resolve_version\n"
                    'printf "%s\\n" "$PXEOS_BUILD_VERSION"\n',
                    TZ=timezone,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "Local-261014-0101\n")
                self.assertEqual(self.date_log.read_text().splitlines(), ["Asia/Shanghai"])

    def test_invalid_ci_version_stops_the_real_startup_prefix_before_dependencies(self) -> None:
        build = (ROOT / "build.sh").read_text(encoding="utf-8")
        prefix = build.split("if ! checkDependencies;", 1)[0]
        prefix = re.sub(
            r"^PROJECT_DIRECTORY=.*$", "PROJECT_DIRECTORY=" + shlex.quote(bash_path(ROOT)),
            prefix, count=1, flags=re.M,
        )
        startup = self.workdir / "startup.sh"
        startup.write_text(prefix + '\nprintf "dependencies would run\\n"\n', encoding="utf-8")
        for version in (None, "", "Local-261014-0101", "invalid"):
            result = self.run_shell(
                f"bash {shlex.quote(bash_path(startup))} --install-dep --fs-download-only -a x64\n",
                GITHUB_ACTIONS="true", PXEOS_BUILD_VERSION=version,
            )
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("PXEOS_BUILD_VERSION", result.stderr)
            self.assertNotIn("dependencies would run", result.stdout)

    def test_build_stamps_only_the_copied_overlay_with_one_resolved_version(self) -> None:
        build = (ROOT / "build.sh").read_text(encoding="utf-8")
        self.assertLess(build.index("rootpxe_build_resolve_version"), build.index("if ! checkDependencies;"))
        self.assertEqual(build.count("rootpxe_build_resolve_version"), 1)
        self.assertNotIn("date +%Y%m%d", build)
        filesystem = build.split("function buildFilesystem()", 1)[1].split("function buildKernel()", 1)[0]
        self.assertLess(filesystem.index('rsync -avPrI "$PROJECT_DIRECTORY/Buildroot/"'), filesystem.index("rootpxe_build_stamp_version"))
        self.assertIn('rootpxe_build_stamp_version board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh "$PXEOS_BUILD_VERSION" || return 1', filesystem)
        self.assertIn("export initversion=unbuilt\n", FUNCS.read_text(encoding="utf-8"))
        before = FUNCS.read_bytes()
        version = "Release-261014-0101-1234567890-2"
        for arch in ("x64", "x86", "arm64"):
            copied = self.workdir / arch / "funcs.sh"
            copied.parent.mkdir()
            shutil.copyfile(FUNCS, copied)
            result = self.run_shell(
                f"source {shlex.quote(bash_path(HELPER))}\n"
                f"rootpxe_build_stamp_version {shlex.quote(bash_path(copied))} \"$PXEOS_BUILD_VERSION\"\n",
                PXEOS_BUILD_VERSION=version,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("export initversion=" + version + "\n", copied.read_text(encoding="utf-8"))
            self.assertEqual(copied.read_text(encoding="utf-8").splitlines()[2:], FUNCS.read_text(encoding="utf-8").splitlines()[2:])
        self.assertEqual(FUNCS.read_bytes(), before)
        self.assertFalse(self.date_log.exists())

    def test_overlay_copy_failure_stops_before_stamping_a_previous_image(self) -> None:
        build = (ROOT / "build.sh").read_text(encoding="utf-8")
        filesystem = re.search(r"^function buildFilesystem\(\) \{\n.*?^\}\n", build, re.M | re.S).group(0)
        source = self.workdir / "fssourcex64"
        source.mkdir()
        (source / ".packConfDone").touch()
        result = self.run_shell(
            filesystem
            + '\nrootpxe_build_apply_filesystem_patches() { :; }; dots() { :; }\n'
            + 'rsync() { printf "copy failed\\n" >&2; return 7; }\n'
            + 'rootpxe_build_stamp_version() { printf "unexpected stamp\\n"; }\n'
            + 'make() { printf "unexpected build\\n"; return 99; }\n'
            + f'PROJECT_DIRECTORY={shlex.quote(bash_path(ROOT))}\n'
            + 'BUILDROOT_VERSION=2026.02.1\n'
            + f'cd {shlex.quote(bash_path(self.workdir))}\nif buildFilesystem x64; then rc=0; else rc=$?; fi; exit "$rc"\n',
            PXEOS_BUILD_VERSION="Release-261014-0101",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("copy failed", result.stderr)
        self.assertNotIn("unexpected stamp", result.stdout)
        self.assertNotIn("unexpected build", result.stdout)

    def test_stamp_rejects_bad_versions_missing_duplicate_markers_and_links(self) -> None:
        for text, version in (
            ("export initversion=unbuilt\n", "Release-261014-0101\ntrue"),
            ("export initversion=unbuilt\n", ""),
            ("#!/bin/bash\n", "Release-261014-0101"),
            ("export initversion=unbuilt\nexport initversion=unbuilt\n", "Release-261014-0101"),
        ):
            copied = self.workdir / "bad-funcs.sh"
            copied.write_text(text)
            result = self.run_shell(
                f"source {shlex.quote(bash_path(HELPER))}\n"
                f"rootpxe_build_stamp_version {shlex.quote(bash_path(copied))} \"$PXEOS_BUILD_VERSION\"\n",
                PXEOS_BUILD_VERSION=version,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(copied.read_text(), text)
        link = self.workdir / "funcs-link.sh"
        try:
            link.symlink_to(copied)
        except OSError as error:
            self.skipTest(f"符号链接不可用: {error}")
        result = self.run_shell(
            f"source {shlex.quote(bash_path(HELPER))}\n"
            f"rootpxe_build_stamp_version {shlex.quote(bash_path(link))} Release-261014-0101\n",
        )
        self.assertNotEqual(result.returncode, 0)


class WorkflowVersionTests(unittest.TestCase):
    def workflows(self):
        for filename, prefix in (("release.yml", "Release"), ("beta.yml", "Beta")):
            yield (ROOT / ".github/workflows" / filename).read_text(encoding="utf-8"), prefix

    def test_all_build_jobs_and_publication_depend_directly_on_the_same_metadata(self) -> None:
        for workflow, _ in self.workflows():
            metadata = job_block(workflow, "release_metadata")
            self.assertIn("tag_name: ${{ steps.naming.outputs.tag_name }}", metadata)
            self.assertIn("release_name: ${{ steps.naming.outputs.release_name }}", metadata)
            self.assertNotIn("contents: write", metadata)
            for job in ("download_filesystem_packages", *(f"build_{kind}_{arch}" for kind in ("kernel", "initrd") for arch in ("arm64", "x86", "x64")), "release"):
                block = job_block(workflow, job)
                before_steps = block.split("    steps:\n", 1)[0]
                self.assertIn("release_metadata", before_steps, job)
                if job != "release":
                    self.assertIn("PXEOS_BUILD_VERSION: ${{ needs.release_metadata.outputs.tag_name }}", before_steps, job)
                else:
                    self.assertIn("TAG_NAME: ${{ needs.release_metadata.outputs.tag_name }}", before_steps)
                    self.assertIn("RELEASE_NAME: ${{ needs.release_metadata.outputs.release_name }}", before_steps)
            self.assertEqual(workflow.count("date '+%y%m%d-%H%M'"), 1)
            self.assertEqual(workflow.count("--fallback-tag"), 1)

    def test_metadata_collision_is_chosen_before_build_and_equals_every_runtime_and_manifest(self) -> None:
        for workflow, prefix in self.workflows():
            for collision in ("false", "true"):
                with self.subTest(prefix=prefix, collision=collision), tempfile.TemporaryDirectory() as directory:
                    workdir = Path(directory)
                    outputs = workdir / "outputs"
                    date_log = workdir / "date.log"
                    gh_log = workdir / "gh.log"
                    fake_gh = workdir / "gh"
                    fake_gh.write_text(
                        '#!/usr/bin/env bash\nset -eu\nprintf "%s\\n" "$*" >> "$GH_LOG"\n'
                        'if [[ ${COLLISION:-false} == true && $* == *"/$BASE_TAG" ]]; then exit 0; fi\n'
                        "echo 'HTTP 404 Not Found' >&2; exit 1\n",
                    )
                    fake_gh.chmod(0o755)
                    naming = step_run(job_block(workflow, "release_metadata"), "Select canonical release metadata")
                    env = os.environ | {
                        "PXEOS_REQUIRED_SERVER_VERSION": "1.0.1", "GITHUB_OUTPUT": bash_path(outputs), "DATE_LOG": bash_path(date_log),
                        "GH_BIN": bash_path(fake_gh), "GH_LOG": bash_path(gh_log),
                        "GITHUB_REPOSITORY": "swireb/pxeos", "GITHUB_RUN_ID": "1234567890", "GITHUB_RUN_ATTEMPT": "2",
                        "BASE_TAG": f"{prefix}-261014-0101", "COLLISION": collision, "TZ": "America/New_York",
                    }
                    result = subprocess.run(
                        [BASH, "-c", 'set -euo pipefail\n' + SHANGHAI_CLOCK + naming],
                        cwd=ROOT, env=env, text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    metadata = dict(line.split("=", 1) for line in outputs.read_text().splitlines())
                    canonical = f"{prefix}-261014-0101" + ("-1234567890-2" if collision == "true" else "")
                    self.assertEqual(metadata, {"server_version": "1.0.1", "release_name": f"{prefix}-261014-0101", "tag_name": canonical})
                    self.assertEqual(date_log.read_text().splitlines(), ["Asia/Shanghai"])
                    self.assertNotRegex(gh_log.read_text(), r"POST|PATCH|UPLOAD|DELETE")
                    for arch, kernel, initrd in (("x64", "bzImage", "init.xz"), ("x86", "bzImage32", "init_32.xz"), ("arm64", "arm_Image", "arm_init.cpio.gz")):
                        copied = workdir / f"{arch}-funcs.sh"
                        shutil.copyfile(FUNCS, copied)
                        result = subprocess.run(
                            [BASH, "-c", f"set -euo pipefail\nsource {shlex.quote(bash_path(HELPER))}\nrootpxe_build_resolve_version\nrootpxe_build_stamp_version {shlex.quote(bash_path(copied))} \"$PXEOS_BUILD_VERSION\"\n"],
                            cwd=ROOT, env=env | {"GITHUB_ACTIONS": "true", "PXEOS_BUILD_VERSION": canonical}, text=True, capture_output=True,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("export initversion=" + canonical + "\n", copied.read_text(encoding="utf-8"))
                        (workdir / kernel).write_bytes(b"mock kernel\n")
                        (workdir / initrd).write_bytes(copied.read_bytes())
                    for channel in (None, "latest" if prefix == "Release" else "beta"):
                        output = workdir / f"{channel or 'history'}.json"
                        command = [sys.executable, str(GENERATOR), "--required-server-version", "1.0.1", "--input-dir", str(workdir), "--repo", "swireb/pxeos", "--tag", canonical, "--output", str(output), "--require-all"]
                        if channel:
                            command.extend(("--download-channel", channel))
                        result = subprocess.run(command, text=True, capture_output=True)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        manifest = json.loads(output.read_text())
                        self.assertEqual([entry["version"] for entry in manifest["kernels"]], [canonical] * 3)
                        for entry in manifest["kernels"]:
                            token = re.search(r"^export initversion=(.*)$", (workdir / (entry["arch"] + "-funcs.sh")).read_text(encoding="utf-8"), re.M).group(1)
                            self.assertEqual(entry["version"], token)
                    self.assertEqual(date_log.read_text().splitlines(), ["Asia/Shanghai"])

    def test_occupied_selected_tag_fails_before_publication_without_fallback_or_renaming(self) -> None:
        for workflow, prefix in self.workflows():
            release = job_block(workflow, "release")
            recheck = step_run(release, "Validate historical release tag")
            self.assertNotIn("--fallback-tag", recheck)
            self.assertNotRegex(recheck, r"\bdate\s")
            self.assertNotRegex(release, r"(?:TAG_NAME|RELEASE_NAME)=")
            self.assertLess(release.index("Run final sha256 checksum"), release.index("Validate historical release tag"))
            self.assertLess(release.index("Validate historical release tag"), release.index("Create GitHub Release"))
            with tempfile.TemporaryDirectory() as directory:
                workdir = Path(directory)
                fake_gh = workdir / "gh"
                log = workdir / "gh.log"
                fake_gh.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$GH_LOG"\nexit 0\n')
                fake_gh.chmod(0o755)
                result = subprocess.run(
                    [BASH, "-c", "set -euo pipefail\n" + recheck + '\nprintf "publication would run\\n"\n'],
                    cwd=ROOT, env=os.environ | {"GH_BIN": bash_path(fake_gh), "GH_LOG": bash_path(log), "GITHUB_REPOSITORY": "swireb/pxeos", "TAG_NAME": f"{prefix}-261014-0101-1234567890-2"},
                    text=True, capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("publication would run", result.stdout)
                self.assertIn("already exists", result.stderr)
                self.assertNotRegex(log.read_text(), r"POST|PATCH|UPLOAD|DELETE")


class RuntimeVersionTests(unittest.TestCase):
    def test_banner_keeps_the_local_token_separate_from_numeric_api_version(self) -> None:
        text = FUNCS.read_text(encoding="utf-8")
        console = text.split("rootpxe_console_message()", 1)[1].split("# Appends dots", 1)[0]
        console = "rootpxe_console_message()" + console
        banner = shell_function(text, "displayBanner")
        for local_version in ("Release-261014-0101-1234567890-2", "Beta-261014-0101", "Local-261014-0101", "unbuilt"):
            for response, api in (("1", "1"), ('{"version":"1"}', "1"), ('{"version":1}', "1"), ('{"version":"Release-991231-2359"}', "unavailable")):
                with self.subTest(local=local_version, health=response):
                    result = subprocess.run(
                        [BASH, "-c", console + banner + '\ncurl() { printf "%s\\n" "$HEALTH_RESPONSE"; }; displayBanner\n'],
                        env=os.environ | {"initversion": local_version, "HEALTH_RESPONSE": response, "pxeapi": "https://example.invalid/"},
                        text=True, capture_output=True, encoding="utf-8",
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("[INFO]  PXEOS version: " + local_version + "\n", result.stdout)
                    self.assertIn("[INFO]  API version: " + api + "\n", result.stdout)
                    self.assertNotIn("[INFO]  Version:", result.stdout)
                    self.assertNotIn("Init version:", result.stdout)

    def test_network_reads_only_the_embedded_safe_token_without_sourcing_runtime_code(self) -> None:
        reader = shell_function(NETWORK.read_text(encoding="utf-8"), "pxeos_network_init_version")
        for version, expected in (
            ("Release-261014-0101-1234567890-2", "Release-261014-0101-1234567890-2"),
            ("Beta-261014-0101", "Beta-261014-0101"), ("Local-261014-0101", "Local-261014-0101"),
            ("unbuilt", "unbuilt"), ("20261014", "unavailable"),
            ("Release-261014-0101$(touch injected)", "unavailable"), ("Release-261014-0101\nexport initversion=Beta-261014-0101", "unavailable"),
            ("Release-261014-0101-" + "1" * 65 + "-1", "unavailable"),
        ):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                fixture = Path(directory) / "funcs.sh"
                marker = Path(directory) / "injected"
                fixture.write_text("export initversion=" + version + "\ntouch " + bash_path(marker) + "\n", encoding="utf-8", newline="\n")
                result = subprocess.run(
                    [BASH, "-c", 'export PATH="/usr/bin:/bin:$PATH"\n' + reader.replace("/usr/share/pxeos/lib/funcs.sh", bash_path(fixture)) + "\npxeos_network_init_version\n"],
                    text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected, result.stderr)
                self.assertFalse(marker.exists())
        self.assertIn('pxeos_network_message INFO "PXEOS version: $(pxeos_network_init_version)"', NETWORK.read_text(encoding="utf-8"))

    def test_failed_api_display_request_keeps_local_version_and_has_a_short_deadline(self) -> None:
        text = FUNCS.read_text(encoding="utf-8")
        console = "rootpxe_console_message()" + text.split("rootpxe_console_message()", 1)[1].split("# Appends dots", 1)[0]
        banner = shell_function(text, "displayBanner")
        result = subprocess.run(
            [BASH, "-c", console + banner + '\ncurl() { return 28; }; displayBanner\n'],
            env=os.environ | {"initversion": "Release-261014-0101-1234-2", "pxeapi": "https://example.invalid/"},
            text=True, capture_output=True, encoding="utf-8",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[INFO]  PXEOS version: Release-261014-0101-1234-2\n", result.stdout)
        self.assertIn("[INFO]  API version: unavailable\n", result.stdout)
        self.assertIn("--connect-timeout 3", banner)
        self.assertIn("--max-time 5", banner)


if __name__ == "__main__":
    unittest.main()
