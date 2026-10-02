#!/usr/bin/env python3
"""Offline contracts for release naming and selected beta architectures."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from itertools import product


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "check-release-tag.sh"
BASH = shutil.which("bash") or r"C:\\Program Files\\Git\\bin\\bash.exe"


def git_bash_path(path: Path) -> str:
    if os.name != "nt" or not path.drive:
        return str(path)
    return "/" + path.drive[0].lower() + path.as_posix()[2:]


class HistoricalTagNamingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tempdir.name)
        self.log = self.workdir / "gh.log"
        self.fake_gh = self.workdir / "gh"
        self.fake_gh.write_text(
            "#!/usr/bin/env bash\nset -eu\n"
            "printf '%s\\n' \"$*\" >> \"$GH_LOG\"\n"
            "case \"$*\" in\n"
            "  *base*) state=${GH_BASE_STATE:-missing} ;;\n"
            "  *fallback*) state=${GH_FALLBACK_STATE:-missing} ;;\n"
            "  *) state=missing ;;\n"
            "esac\n"
            "case \"$state\" in\n"
            "  missing) echo 'HTTP 404 Not Found' >&2; exit 1 ;;\n"
            "  exists) exit 0 ;;\n"
            "  forbidden) echo 'HTTP 403 Forbidden' >&2; exit 1 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        self.fake_gh.chmod(0o755)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def check(self, *extra: str, **states: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                BASH,
                git_bash_path(CHECKER),
                "--repo",
                "swireb/pxeos",
                "--tag",
                "base",
                *extra,
            ],
            text=True,
            capture_output=True,
            env=os.environ
            | {
                "GH_BIN": git_bash_path(self.fake_gh),
                "GH_LOG": git_bash_path(self.log),
                **states,
            },
        )

    def test_base_tag_is_printed_when_both_markers_are_missing(self) -> None:
        result = self.check("--fallback-tag", "fallback")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "base\n")

    def test_legacy_validation_mode_keeps_stdout_empty(self) -> None:
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_existing_base_uses_fallback_without_changing_display_name(self) -> None:
        result = self.check("--fallback-tag", "fallback", GH_BASE_STATE="exists")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "fallback\n")

    def test_existing_fallback_fails_closed(self) -> None:
        result = self.check(
            "--fallback-tag", "fallback", GH_BASE_STATE="exists", GH_FALLBACK_STATE="exists"
        )
        self.assertNotEqual(result.returncode, 0)

    def test_non_404_marker_lookup_fails_closed_without_trying_fallback(self) -> None:
        result = self.check("--fallback-tag", "fallback", GH_BASE_STATE="forbidden")
        self.assertNotEqual(result.returncode, 0)
        log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertNotIn("fallback", log)


class WorkflowNamingAndArchitectureTests(unittest.TestCase):
    def workflows(self) -> tuple[str, str]:
        return (
            (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8"),
            (ROOT / ".github" / "workflows" / "beta.yml").read_text(encoding="utf-8"),
        )

    def test_release_has_no_dispatch_options_and_fixed_release_metadata(self) -> None:
        release, _ = self.workflows()
        self.assertNotIn("workflow_dispatch:\n    inputs:", release)
        self.assertIn("name: Build Release", release)
        self.assertIn("RELEASE_NAME=Release-${release_stamp}", release)
        self.assertIn("--channel latest", release)
        self.assertIn("prerelease: false", release)
        self.assertIn("make_latest: 'true'", release)

    def test_both_channels_use_the_same_manifest_filename(self) -> None:
        for workflow in self.workflows():
            self.assertIn("distribution-files/pxeos.json", workflow)
            self.assertNotIn("pxeos-latest.json", workflow)
            self.assertNotIn("pxeos-beta.json", workflow)

    def test_beta_architecture_inputs_gate_complete_pairs_and_release(self) -> None:
        _, beta = self.workflows()
        for arch in ("arm64", "x64", "x86"):
            self.assertIn(f"      {arch}:\n        type: boolean", beta)
            self.assertIn(f'description: "{arch}"', beta)
            self.assertIn(f"if: ${{{{ inputs.{arch} }}}}", beta)
            self.assertIn(f"build_kernel_{arch}:", beta)
            self.assertIn(f"build_initrd_{arch}:", beta)
        self.assertNotIn("publish_beta", beta)
        self.assertNotIn("inputs.kernel_arm64", beta)
        self.assertIn("No architectures selected", beta)
        self.assertIn("!contains(needs.*.result, 'failure')", beta)
        self.assertIn("!contains(needs.*.result, 'cancelled')", beta)
        self.assertIn("        download_filesystem_packages,", beta)
        self.assertIn("prerelease: true", beta)
        self.assertIn("make_latest: 'false'", beta)
        self.assertIn("- name: Get versions from build.sh", beta)
        self.assertIn("Back up existing boot files before use.", beta)
        self.assertIn("${{ env.LINUX_KERNEL_VER }}", beta)
        self.assertIn("${{ env.BUILDROOT_VER }}", beta)

    def test_beta_input_validation_covers_all_architecture_combinations(self) -> None:
        beta = self.workflows()[1]
        validation = textwrap.dedent(
            beta.split("        run: |\n", 1)[1].split("\n\n  download_filesystem_packages:", 1)[0]
        )
        for arm64, x64, x86 in product((False, True), repeat=3):
            selected = {"arm64": arm64, "x64": x64, "x86": x86}
            with self.subTest(selected=selected):
                result = subprocess.run(
                    [BASH, "-c", validation],
                    text=True,
                    capture_output=True,
                    env=os.environ | {arch.upper(): str(value).lower() for arch, value in selected.items()},
                )
                self.assertEqual(result.returncode == 0, any(selected.values()), result.stderr)
                for arch in selected:
                    kernel = beta.split(f"  build_kernel_{arch}:\n", 1)[1].split("\n  build_", 1)[0]
                    initrd = beta.split(f"  build_initrd_{arch}:\n", 1)[1].split("\n  build_", 1)[0]
                    self.assertIn("if: ${{ inputs.%s }}" % arch, kernel)
                    self.assertIn("if: ${{ inputs.%s }}" % arch, initrd)

    def test_timestamp_run_blocks_sample_shanghai_time_once(self) -> None:
        for workflow, prefix in zip(self.workflows(), ("Release", "Beta")):
            naming_step = textwrap.dedent(
                workflow.split("      - name: Set release and tag names\n        run: |\n", 1)[1]
                .split("      - name:", 1)[0]
            )
            with tempfile.TemporaryDirectory() as tempdir:
                workdir = Path(tempdir)
                env_file = workdir / "github-env"
                date_log = workdir / "date.log"
                result = subprocess.run(
                    [
                        BASH,
                        "-c",
                        'date() { printf "%s\\n" "${TZ:-missing}" >> "$DATE_LOG"; printf "%s\\n" "261002-1530"; }; '
                        + naming_step,
                    ],
                    text=True,
                    capture_output=True,
                    env=os.environ | {
                        "GITHUB_ENV": git_bash_path(env_file),
                        "DATE_LOG": git_bash_path(date_log),
                    },
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(date_log.read_text(encoding="utf-8").splitlines(), ["Asia/Shanghai"])
                self.assertEqual(
                    env_file.read_text(encoding="utf-8").splitlines(),
                    [
                        f"RELEASE_NAME={prefix}-261002-1530",
                        f"TAG_NAME={prefix}-261002-1530",
                    ],
                )
                self.assertIn("-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}", workflow)


if __name__ == "__main__":
    unittest.main()
