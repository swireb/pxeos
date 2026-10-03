#!/usr/bin/env python3
"""离线覆盖有限自定义 Buildroot 包的受哈希保护源码预置下载。"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "download_helpers.sh"
BUILD = ROOT / "build.sh"
CUSTOM_SOURCE_SPECS = {
    "cabextract": (
        "CABEXTRACT",
        "1.11",
        "cabextract-1.11.tar.gz",
        "https://www.cabextract.org.uk",
        "b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6",
    ),
    "chntpw": (
        "CHNTPW",
        "140201",
        "chntpw-source-140201.zip",
        "https://pogostick.net/~pnh/ntpasswd",
        "96e20905443e24cba2f21e51162df71dd993a1c02bfa12b1be2d0801a4ee2ccc",
    ),
    "libhivex": (
        "LIBHIVEX",
        "1.3.24",
        "hivex-1.3.24.tar.gz",
        "https://download.libguestfs.org/hivex",
        "a52fa45cecc9a78adb2d28605d68261e4f1fd4514a778a5473013d2ccc8a193c",
    ),
    "partclone": (
        "PARTCLONE",
        "0.3.48",
        "partclone-0.3.48.tar.gz",
        "https://github.com/Thomas-Tsai/partclone/archive/0.3.48",
        "af4f1c93fb2401eb617f1eafc13f115d7f583f6851a8195728d17b520fec7685",
    ),
    "testdisk": (
        "TESTDISK",
        "7.2",
        "testdisk-7.2.tar.bz2",
        "https://www.cgsecurity.org",
        "f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f",
    ),
    "partimage": (
        "PARTIMAGE",
        "0.6.9",
        "partimage-0.6.9.tar.bz2",
        "https://downloads.sourceforge.net/project/partimage/stable/0.6.9",
        "753a6c81f4be18033faed365320dc540fe5e58183eaadcd7a5b69b096fec6635",
    ),
}
CUSTOM_SOURCE_URLS = {
    "cabextract": (
        "https://www.cabextract.org.uk/cabextract-1.11.tar.gz",
        "https://deb.debian.org/debian/pool/main/c/cabextract/cabextract_1.11.orig.tar.gz",
    ),
    "chntpw": (
        "https://pogostick.net/~pnh/ntpasswd/chntpw-source-140201.zip",
        "https://distfiles.macports.org/chntpw/chntpw-source-140201.zip",
    ),
    "libhivex": (
        "https://download.libguestfs.org/hivex/hivex-1.3.24.tar.gz",
        "https://deb.debian.org/debian/pool/main/h/hivex/hivex_1.3.24.orig.tar.gz",
    ),
    "partclone": (
        "https://github.com/Thomas-Tsai/partclone/archive/0.3.48/partclone-0.3.48.tar.gz",
        "https://codeload.github.com/Thomas-Tsai/partclone/tar.gz/refs/tags/0.3.48",
    ),
    "testdisk": (
        "https://www.cgsecurity.org/testdisk-7.2.tar.bz2",
        "https://distfiles.macports.org/testdisk/testdisk-7.2.tar.bz2",
    ),
    "partimage": (
        "https://downloads.sourceforge.net/project/partimage/stable/0.6.9/partimage-0.6.9.tar.bz2",
        "https://deb.debian.org/debian/pool/main/p/partimage/partimage_0.6.9.orig.tar.bz2",
    ),
}
CONFIGS = tuple(ROOT / "configs" / name for name in ("fsx86.config", "fsx64.config", "fsarm64.config"))
HTTP_SOURCE_PACKAGES = (
    ROOT / "Buildroot" / "package" / "chntpw" / "chntpw.mk",
    ROOT / "Buildroot" / "package" / "testdisk" / "testdisk.mk",
    ROOT / "Buildroot" / "package" / "partimage" / "partimage.mk",
)
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
BETA_WORKFLOW = ROOT / ".github" / "workflows" / "beta.yml"
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"
EXPECTED_HASH = CUSTOM_SOURCE_SPECS["cabextract"][4]
EXPECTED_CACHE_KEY = (
    "key: buildroot-dl-${{ hashFiles('build.sh', 'download_helpers.sh', "
    "'configs/**', 'Buildroot/package/**') }}"
)


def git_bash_path(path: Path) -> str:
    if os.name != "nt" or not path.drive:
        return str(path)
    return "/" + path.drive[0].lower() + path.as_posix()[2:]


class CabextractDownloadTests(unittest.TestCase):
    @staticmethod
    def workflow_job_block(path: Path, job_name: str) -> str:
        workflow = path.read_text()
        marker = f"\n  {job_name}:\n"
        start = workflow.index(marker) + 1
        next_job = workflow.find("\n  ", start + len(marker))
        while next_job != -1 and workflow[next_job + 3 : next_job + 4] == " ":
            next_job = workflow.find("\n  ", next_job + 1)
        return workflow[start:] if next_job == -1 else workflow[start:next_job]

    @classmethod
    def workflow_steps(cls, path: Path, job_name: str) -> str:
        job = cls.workflow_job_block(path, job_name)
        steps = job.split("    steps:\n", 1)[1]
        return "\n".join(line for line in steps.splitlines() if line.strip())

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.workdir = Path(self.tempdir.name)
        self.payload = self.workdir / "cabextract-1.11.tar.gz"
        self.payload.write_bytes(b"verified cabextract archive\n")
        self.expected_hash = hashlib.sha256(self.payload.read_bytes()).hexdigest()
        self.wget_log = self.workdir / "wget.log"
        self.driver = self.workdir / "driver.sh"
        self.driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"source {shlex.quote(git_bash_path(HELPER))}\n"
            'download_file_sha256 "$@"\n'
        )
        self.mock_bin = self.workdir / "mock-bin"
        self.mock_bin.mkdir()
        mock_wget = self.mock_bin / "wget"
        mock_wget.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "output=''\n"
            "for last; do :; done\n"
            "while (($#)); do\n"
            "  case $1 in\n"
            "    -O) output=$2; shift 2 ;;\n"
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            "printf '%s\\n' \"$last\" >>\"$MOCK_WGET_LOG\"\n"
            "case $last in\n"
            "  https://primary.invalid/*) exit 7 ;;\n"
            "  https://wrong.invalid/*) printf 'wrong archive' >\"$output\" ;;\n"
            "  https://backup.invalid/*|https://www.cabextract.org.uk/cabextract-1.11.tar.gz|https://deb.debian.org/debian/pool/main/c/cabextract/cabextract_1.11.orig.tar.gz) cat \"$MOCK_PAYLOAD\" >\"$output\" ;;\n"
            "  *) exit 8 ;;\n"
            "esac\n"
        )
        mock_wget.chmod(0o755)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_helper(self, destination: Path, *urls: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "MOCK_WGET_LOG": git_bash_path(self.wget_log),
                "MOCK_PAYLOAD": git_bash_path(self.payload),
                "PATH": f"{self.mock_bin}{os.pathsep}{env.get('PATH', '')}",
            }
        )
        command = " ".join(
            [
                f"PATH={shlex.quote(git_bash_path(self.mock_bin))}:$PATH; export PATH; bash",
                shlex.quote(git_bash_path(self.driver)),
                shlex.quote(git_bash_path(destination)),
                shlex.quote(self.expected_hash),
                *(shlex.quote(url) for url in urls),
            ]
        )
        return subprocess.run(
            [BASH, "-lc", command], text=True, capture_output=True, errors="replace", env=env
        )

    def wget_urls(self) -> list[str]:
        if not self.wget_log.exists():
            return []
        return self.wget_log.read_text().splitlines()

    @staticmethod
    def extract_function(name: str) -> str:
        lines = BUILD.read_text().splitlines(keepends=True)
        start = next(
            index
            for index, line in enumerate(lines)
            if line.startswith(f"{name}()") or line.startswith(f"function {name}()")
        )
        end = next(index for index in range(start + 1, len(lines)) if lines[index] == "}\n")
        return "".join(lines[start : end + 1])

    def run_printvars(
        self, prefix: str, version: str, source: str, site: str, output: str
    ) -> subprocess.CompletedProcess[str]:
        (self.mock_bin / "make").write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf '%s' \"$MOCK_PRINTVARS_OUTPUT\"\n"
        )
        (self.mock_bin / "make").chmod(0o755)
        driver = self.workdir / "printvars-driver.sh"
        functions = self.workdir / "printvars-functions.sh"
        functions.write_text(self.extract_function("rootpxe_build_verified_source_metadata"))
        driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"source {shlex.quote(git_bash_path(functions))}\n"
            f"rootpxe_build_verified_source_metadata {shlex.quote(prefix)} {shlex.quote(version)} "
            f"{shlex.quote(source)} {shlex.quote(site)}\n"
        )
        env = os.environ.copy()
        env.update(
            {
                "MOCK_PRINTVARS_OUTPUT": output,
                "PATH": f"{self.mock_bin}{os.pathsep}{env.get('PATH', '')}",
            }
        )
        command = (
            f"PATH={shlex.quote(git_bash_path(self.mock_bin))}:$PATH; export PATH; "
            f"bash {shlex.quote(git_bash_path(driver))}"
        )
        return subprocess.run(
            [BASH, "-lc", command], text=True, capture_output=True, errors="replace", env=env
        )

    def run_backup_site_normalization(self, value: str) -> str:
        functions = self.workdir / "backup-site-functions.sh"
        functions.write_text(self.extract_function("rootpxe_build_normalize_backup_site_config"))
        config = self.workdir / "config"
        config.write_text(f'BR2_BACKUP_SITE="{value}"\nBR2_PRIMARY_SITE=""\n')
        driver = self.workdir / "backup-site-driver.sh"
        driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"source {shlex.quote(git_bash_path(functions))}\n"
            f"rootpxe_build_normalize_backup_site_config {shlex.quote(git_bash_path(config))}\n"
        )
        result = subprocess.run(
            [BASH, "-lc", f"bash {shlex.quote(git_bash_path(driver))}"],
            text=True,
            capture_output=True,
            errors="replace",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return config.read_text()

    def test_valid_cache_is_hash_checked_without_network(self) -> None:
        destination = self.workdir / "path with spaces" / self.payload.name
        destination.parent.mkdir()
        shutil.copyfile(self.payload, destination)

        result = self.run_helper(destination, "https://primary.invalid/cabextract.tar.gz")

        self.assertEqual(result.returncode, 0, f"stdout={result.stdout!r}\nstderr={result.stderr}")
        self.assertEqual(destination.read_bytes(), self.payload.read_bytes())
        self.assertEqual(self.wget_urls(), [])

    def test_primary_failure_falls_back_to_verified_https_source(self) -> None:
        destination = self.workdir / "cache" / self.payload.name
        destination.parent.mkdir()

        result = self.run_helper(
            destination,
            "https://primary.invalid/cabextract.tar.gz",
            "https://backup.invalid/cabextract.tar.gz",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(destination.read_bytes(), self.payload.read_bytes())
        self.assertEqual(
            self.wget_urls(),
            ["https://primary.invalid/cabextract.tar.gz", "https://backup.invalid/cabextract.tar.gz"],
        )

    def test_bad_cache_is_replaced_only_by_hash_verified_download(self) -> None:
        destination = self.workdir / "cache" / self.payload.name
        destination.parent.mkdir()
        destination.write_bytes(b"stale cache")

        result = self.run_helper(destination, "https://backup.invalid/cabextract.tar.gz")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(destination.read_bytes(), self.payload.read_bytes())

    def test_wrong_hash_and_all_source_failures_keep_bad_cache_and_cleanup_temp(self) -> None:
        destination = self.workdir / "cache" / self.payload.name
        destination.parent.mkdir()
        destination.write_bytes(b"stale cache")

        result = self.run_helper(
            destination,
            "https://wrong.invalid/cabextract.tar.gz",
            "https://primary.invalid/cabextract.tar.gz",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_bytes(), b"stale cache")
        self.assertEqual(list(destination.parent.glob(destination.name + ".tmp.*")), [])

    def test_cold_cache_all_source_failures_leave_no_final_file_or_temp(self) -> None:
        destination = self.workdir / "cache" / self.payload.name
        destination.parent.mkdir()

        result = self.run_helper(destination, "https://primary.invalid/cabextract.tar.gz")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())
        self.assertEqual(list(destination.parent.glob(destination.name + ".tmp.*")), [])

    def test_directory_target_is_rejected_without_network(self) -> None:
        destination = self.workdir / "cache" / self.payload.name
        destination.mkdir(parents=True)

        result = self.run_helper(destination, "https://backup.invalid/cabextract.tar.gz")

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(destination.is_dir())
        self.assertEqual(self.wget_urls(), [])

    def test_non_https_source_is_rejected_without_network(self) -> None:
        destination = self.workdir / "cache" / self.payload.name
        destination.parent.mkdir()

        result = self.run_helper(destination, "http://insecure.invalid/cabextract.tar.gz")

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())
        self.assertEqual(self.wget_urls(), [])

    def test_verified_replacement_uses_no_target_directory_fallback(self) -> None:
        self.assertIn("mv -fT --", HELPER.read_text())

    def test_custom_package_sources_use_https_and_unique_pinned_hashes(self) -> None:
        for package, (prefix, version, source, site, expected_hash) in CUSTOM_SOURCE_SPECS.items():
            with self.subTest(package=package):
                package_dir = ROOT / "Buildroot" / "package" / package
                package_mk = package_dir / f"{package}.mk"
                package_hash = package_dir / f"{package}.hash"
                self.assertTrue(package_hash.is_file())
                self.assertIn(f"{prefix}_SITE", package_mk.read_text())
                if package == "partclone":
                    self.assertIn(
                        "$(call github,Thomas-Tsai,partclone,$(PARTCLONE_VERSION))",
                        package_mk.read_text(),
                    )
                else:
                    self.assertIn(site, package_mk.read_text())
                self.assertEqual(
                    package_hash.read_text().count(f"sha256 {expected_hash} {source}"), 1
                )

    def test_verified_source_spec_uses_only_the_approved_https_entries(self) -> None:
        build = BUILD.read_text()
        for package, urls in CUSTOM_SOURCE_URLS.items():
            with self.subTest(package=package):
                for url in urls:
                    self.assertIn(url, build)

    def test_backup_site_migration_and_http_package_sources_are_hardened(self) -> None:
        for config in CONFIGS:
            self.assertIn('BR2_BACKUP_SITE="https://sources.buildroot.net"', config.read_text())
        expected_https_sources = {
            HTTP_SOURCE_PACKAGES[0]: "CHNTPW_SITE = https://pogostick.net/~pnh/ntpasswd",
            HTTP_SOURCE_PACKAGES[1]: "TESTDISK_SITE:=https://www.cgsecurity.org",
            HTTP_SOURCE_PACKAGES[2]: (
                "PARTIMAGE_SITE = https://downloads.sourceforge.net/project/partimage/stable/0.6.9"
            ),
        }
        for package, expected_source in expected_https_sources.items():
            self.assertIn(expected_source, package.read_text())

        expected = 'BR2_BACKUP_SITE="https://sources.buildroot.net"\nBR2_PRIMARY_SITE=""\n'
        for legacy in (
            "http://sources.buildroot.net/",
            "http://sources.buildroot.net",
            "https://sources.buildroot.net/",
        ):
            with self.subTest(legacy=legacy):
                self.assertEqual(self.run_backup_site_normalization(legacy), expected)
        self.assertEqual(
            self.run_backup_site_normalization("https://sources.buildroot.net"), expected
        )
        self.assertEqual(
            self.run_backup_site_normalization("https://mirror.example.invalid/buildroot"),
            'BR2_BACKUP_SITE="https://mirror.example.invalid/buildroot"\nBR2_PRIMARY_SITE=""\n',
        )
        self.assertEqual(
            self.run_backup_site_normalization(""),
            'BR2_BACKUP_SITE=""\nBR2_PRIMARY_SITE=""\n',
        )
        self.assertGreaterEqual(
            BUILD.read_text().count("rootpxe_build_normalize_backup_site_config .config"), 2
        )

    def test_release_and_beta_share_download_cache_contract(self) -> None:
        beta = BETA_WORKFLOW.read_text()
        release = RELEASE_WORKFLOW.read_text()
        self.assertEqual(beta.count(EXPECTED_CACHE_KEY), 4)
        self.assertEqual(release.count(EXPECTED_CACHE_KEY), 4)
        self.assertIn("download_filesystem_packages:\n", release)
        self.assertIn("run: ./build.sh -i --fs-download-only", release)
        for arch in ("arm64", "x86", "x64"):
            self.assertIn(
                f"  build_initrd_{arch}:\n    needs: download_filesystem_packages",
                release,
            )
            self.assertIn(
                f"  build_initrd_{arch}:\n    needs: [input_checks, download_filesystem_packages]",
                beta,
            )

    def test_release_and_beta_share_public_build_steps(self) -> None:
        release = RELEASE_WORKFLOW.read_text()
        beta = BETA_WORKFLOW.read_text()
        arches = ("arm64", "x86", "x64")
        config_names = {
            "arm64": "fsarm64.config",
            "x86": "fsx86.config",
            "x64": "fsx64.config",
        }

        self.assertIn("defaults:\n  run:\n    shell: bash", release)
        self.assertIn("defaults:\n  run:\n    shell: bash", beta)
        self.assertEqual(
            self.workflow_steps(RELEASE_WORKFLOW, "download_filesystem_packages"),
            self.workflow_steps(BETA_WORKFLOW, "download_filesystem_packages"),
        )
        for kind in ("kernel", "initrd"):
            for arch in arches:
                job_name = f"build_{kind}_{arch}"
                with self.subTest(job=job_name):
                    release_job = self.workflow_job_block(RELEASE_WORKFLOW, job_name)
                    beta_job = self.workflow_job_block(BETA_WORKFLOW, job_name)
                    self.assertEqual(
                        "runs-on: ubuntu-24.04" in release_job,
                        "runs-on: ubuntu-24.04" in beta_job,
                    )
                    self.assertTrue("runs-on: ubuntu-24.04" in release_job)
                    self.assertEqual(
                        self.workflow_steps(RELEASE_WORKFLOW, job_name),
                        self.workflow_steps(BETA_WORKFLOW, job_name),
                    )

        for workflow in (release, beta):
            self.assertEqual(workflow.count("- name: Restore Buildroot DL cache"), 4)
            self.assertEqual(workflow.count("- name: Restore Buildroot CCache"), 3)

        for arch in arches:
            config = ROOT / "configs" / config_names[arch]
            self.assertIn(
                f'BR2_CCACHE_DIR="$(HOME)/.buildroot-ccache-{arch}"', config.read_text()
            )
            beta_kernel = self.workflow_job_block(BETA_WORKFLOW, f"build_kernel_{arch}")
            beta_initrd = self.workflow_job_block(BETA_WORKFLOW, f"build_initrd_{arch}")
            release_kernel = self.workflow_job_block(RELEASE_WORKFLOW, f"build_kernel_{arch}")
            release_initrd = self.workflow_job_block(RELEASE_WORKFLOW, f"build_initrd_{arch}")
            self.assertIn(f"if: ${{{{ inputs.{arch} }}}}", beta_kernel)
            self.assertIn(f"if: ${{{{ inputs.{arch} }}}}", beta_initrd)
            self.assertNotIn("\n    if:", release_kernel)
            self.assertNotIn("\n    if:", release_initrd)
            for job in (release_initrd, beta_initrd):
                self.assertIn(f"path: ~/.buildroot-ccache-{arch}", job)
                self.assertIn(f"key: ccache-{arch}", job)
                self.assertIn(f"ccache-{arch}", job)

        self.assertIn("  input_checks:\n", beta)
        release_publish = self.workflow_steps(RELEASE_WORKFLOW, "release")
        beta_publish = self.workflow_steps(BETA_WORKFLOW, "release")
        release_order = [
            "Generate release download manifest",
            "Run final sha256 checksum",
            "Create GitHub Release",
            "Generate latest download manifest",
            "Publish latest download manifest",
        ]
        self.assertEqual(sorted(release_order, key=release_publish.index), release_order)
        self.assertLess(
            beta_publish.index("Generate beta download manifest"),
            beta_publish.index("Run final sha256 checksum"),
        )
        self.assertIn("--require-all", release_publish)
        self.assertNotIn("--require-all", beta_publish)
        self.assertIn("- name: Download distribution files", release_publish)
        self.assertIn("- name: Download distribution files", beta_publish)
        self.assertIn("- name: Create GitHub Release", release_publish)
        self.assertIn("- name: Create GitHub Release", beta_publish)
        self.assertIn("prerelease: false", release_publish)
        self.assertIn("make_latest: 'true'", release_publish)
        self.assertIn("prerelease: true", beta_publish)
        self.assertIn("make_latest: 'false'", beta_publish)

    def test_build_uses_strict_printvars_and_propagates_source_failures(self) -> None:
        build = BUILD.read_text()
        self.assertIn(
            'make -s printvars VARS="${prefix}_VERSION ${prefix}_SOURCE ${prefix}_SITE ${prefix}_DL_DIR"',
            build,
        )
        self.assertIn("BR2_PRIMARY_SITE_ONLY=y", build)
        self.assertIn("make source || return 1", build)
        self.assertIn("cd .. || return 1", build)

    def test_printvars_accepts_actual_package_directory_with_spaces(self) -> None:
        directory = self.workdir / "cache with spaces" / "cabextract"
        prefix, version, source, site, _ = CUSTOM_SOURCE_SPECS["cabextract"]
        result = self.run_printvars(
            prefix,
            version,
            source,
            site,
            "\n".join(
                (
                    f"{prefix}_DL_DIR={git_bash_path(directory)}",
                    f"{prefix}_SITE={site}",
                    f"{prefix}_SOURCE={source}",
                    f"{prefix}_VERSION={version}",
                )
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), git_bash_path(directory))

    def test_printvars_accepts_package_directory_containing_pipe(self) -> None:
        directory = self.workdir / "cache|with|pipe" / "cabextract"
        prefix, version, source, site, _ = CUSTOM_SOURCE_SPECS["cabextract"]
        result = self.run_printvars(
            prefix,
            version,
            source,
            site,
            "\n".join(
                (
                    f"{prefix}_DL_DIR={git_bash_path(directory)}",
                    f"{prefix}_SITE={site}",
                    f"{prefix}_SOURCE={source}",
                    f"{prefix}_VERSION={version}",
                )
            ),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), git_bash_path(directory))

    def test_printvars_rejects_empty_multiline_and_wrong_variable(self) -> None:
        prefix, version, source, site, _ = CUSTOM_SOURCE_SPECS["cabextract"]
        for output in (
            f"{prefix}_VERSION={version}\n{prefix}_SOURCE={source}\n{prefix}_SITE={site}\n{prefix}_DL_DIR=",
            f"{prefix}_VERSION={version}\n{prefix}_SOURCE={source}\n{prefix}_SITE={site}\n{prefix}_DL_DIR=/one\nextra",
            f"OTHER_VERSION={version}\n{prefix}_SOURCE={source}\n{prefix}_SITE={site}\n{prefix}_DL_DIR=/one",
            f"{prefix}_VERSION=wrong\n{prefix}_SOURCE={source}\n{prefix}_SITE={site}\n{prefix}_DL_DIR=/one",
            f"{prefix}_VERSION={version}\n{prefix}_SOURCE=wrong.tar.gz\n{prefix}_SITE={site}\n{prefix}_DL_DIR=/one",
            f"{prefix}_VERSION={version}\n{prefix}_SOURCE={source}\n{prefix}_SITE=https://wrong.invalid\n{prefix}_DL_DIR=/one",
            f"{prefix}_VERSION={version}\n{prefix}_SOURCE={source}\n{prefix}_SITE={site}\n{prefix}_DL_DIR=relative/cache",
            f"{prefix}_VERSION={version}\n{prefix}_SOURCE={source}\n{prefix}_SITE={site}\n{prefix}_DL_DIR=/trailing-space ",
            f"{prefix}_VERSION={version}\n{prefix}_SOURCE={source}\n{prefix}_SITE={site}\n{prefix}_DL_DIR= /leading-space",
            f"{prefix}_VERSION={version}\n{prefix}_SOURCE={source}\n{prefix}_SITE={site}\n{prefix}_DL_DIR=/one\r",
        ):
            with self.subTest(output=output):
                result = self.run_printvars(prefix, version, source, site, output)
                self.assertNotEqual(result.returncode, 0)

    def test_verified_source_preseed_covers_only_the_fixed_six_package_list(self) -> None:
        functions = self.workdir / "seed-list-functions.sh"
        functions.write_text(self.extract_function("rootpxe_build_seed_verified_sources"))
        config = self.workdir / ".config"
        config.write_text(
            "".join(f"BR2_PACKAGE_{prefix}=y\n" for prefix, *_ in CUSTOM_SOURCE_SPECS.values())
        )
        log = self.workdir / "seed-list.log"
        driver = self.workdir / "seed-list-driver.sh"
        driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "rootpxe_build_seed_verified_source() { printf '%s\\n' \"$1\" >>\"$SEED_LOG\"; }\n"
            f"source {shlex.quote(git_bash_path(functions))}\n"
            "rootpxe_build_seed_verified_sources\n"
        )
        env = os.environ.copy()
        env["SEED_LOG"] = git_bash_path(log)
        result = subprocess.run(
            [BASH, "-lc", f"cd {shlex.quote(git_bash_path(self.workdir))} && bash {shlex.quote(git_bash_path(driver))}"],
            text=True,
            capture_output=True,
            errors="replace",
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().splitlines(), list(CUSTOM_SOURCE_SPECS))

    def test_primary_site_only_skips_verified_source_preseed_without_network(self) -> None:
        functions = self.workdir / "primary-only-functions.sh"
        functions.write_text(self.extract_function("rootpxe_build_seed_verified_sources"))
        config = self.workdir / ".config"
        config.write_text("BR2_PRIMARY_SITE_ONLY=y\nBR2_PACKAGE_CABEXTRACT=y\n")
        driver = self.workdir / "primary-only-driver.sh"
        driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "rootpxe_build_seed_verified_source() { exit 91; }\n"
            f"source {shlex.quote(git_bash_path(functions))}\n"
            "rootpxe_build_seed_verified_sources\n"
        )
        result = subprocess.run(
            [BASH, "-lc", f"cd {shlex.quote(git_bash_path(self.workdir))} && bash {shlex.quote(git_bash_path(driver))}"],
            text=True,
            capture_output=True,
            errors="replace",
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_package_hash_metadata_fails_closed_when_missing_wrong_or_duplicated(self) -> None:
        functions = self.workdir / "hash-functions.sh"
        functions.write_text(self.extract_function("rootpxe_build_verified_source_hash"))
        project = self.workdir / "hash-project"
        package = project / "Buildroot" / "package" / "cabextract"
        package.mkdir(parents=True)
        hash_file = package / "cabextract.hash"
        driver = self.workdir / "hash-driver.sh"
        driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"PROJECT_DIRECTORY={shlex.quote(git_bash_path(project))}\n"
            f"source {shlex.quote(git_bash_path(functions))}\n"
            "rootpxe_build_verified_source_hash cabextract cabextract-1.11.tar.gz "
            f"{EXPECTED_HASH}\n"
        )
        valid = f"sha256 {EXPECTED_HASH} cabextract-1.11.tar.gz\n"
        cases = {
            "valid": (valid, True),
            "missing": ("", False),
            "wrong": ("sha256 " + "0" * 64 + " cabextract-1.11.tar.gz\n", False),
            "duplicate": (valid + valid, False),
        }
        for name, (contents, should_pass) in cases.items():
            with self.subTest(name=name):
                hash_file.write_text(contents)
                result = subprocess.run(
                    [BASH, "-lc", f"bash {shlex.quote(git_bash_path(driver))}"],
                    text=True,
                    capture_output=True,
                    errors="replace",
                )
                self.assertEqual(result.returncode == 0, should_pass, result.stderr)

    def test_each_enabled_custom_package_uses_its_approved_spec_and_hash(self) -> None:
        functions = self.workdir / "all-seed-functions.sh"
        functions.write_text(
            "\n".join(
                self.extract_function(name)
                for name in (
                    "rootpxe_build_verified_source_spec",
                    "rootpxe_build_verified_source_metadata",
                    "rootpxe_build_verified_source_hash",
                    "rootpxe_build_seed_verified_source",
                    "rootpxe_build_seed_verified_sources",
                )
            )
        )
        mock_make = self.mock_bin / "make"
        mock_make.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf '%s\\n' \"$*\" >>\"$MOCK_MAKE_LOG\"\n"
            "printf '%s\\n' \"${MOCK_PREFIX}_DL_DIR=${MOCK_DL_DIR}\" "
            "\"${MOCK_PREFIX}_SITE=${MOCK_SITE}\" "
            "\"${MOCK_PREFIX}_SOURCE=${MOCK_SOURCE}\" "
            "\"${MOCK_PREFIX}_VERSION=${MOCK_VERSION}\"\n"
        )
        mock_make.chmod(0o755)
        config = self.workdir / ".config"
        spy_log = self.workdir / "download-spy.log"
        make_log = self.workdir / "make-spy.log"
        driver = self.workdir / "all-seed-driver.sh"
        driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"PROJECT_DIRECTORY={shlex.quote(git_bash_path(ROOT))}\n"
            f"source {shlex.quote(git_bash_path(functions))}\n"
            "temp_root=$(mktemp -d /tmp/pxeos-source-seed-XXXXXX)\n"
            "export MOCK_DL_DIR=\"$temp_root/cache dir\"\n"
            "trap 'rm -rf -- \"$temp_root\"' EXIT\n"
            "download_file_sha256() {\n"
            "    printf '%s\\t%s\\t%s\\t%s\\n' \"$1\" \"$2\" \"$3\" \"${4:-}\" >>\"$SPY_LOG\"\n"
            "}\n"
            "rootpxe_build_seed_verified_sources\n"
        )
        for package, (prefix, version, source, site, expected_hash) in CUSTOM_SOURCE_SPECS.items():
            with self.subTest(package=package):
                config.write_text(f"BR2_PACKAGE_{prefix}=y\n")
                env = os.environ.copy()
                env.update(
                    {
                        "MOCK_PREFIX": prefix,
                        "MOCK_VERSION": version,
                        "MOCK_SOURCE": source,
                        "MOCK_SITE": site,
                        "SPY_LOG": git_bash_path(spy_log),
                        "MOCK_MAKE_LOG": git_bash_path(make_log),
                        "PATH": f"{self.mock_bin}{os.pathsep}{env.get('PATH', '')}",
                    }
                )
                if spy_log.exists():
                    spy_log.unlink()
                if make_log.exists():
                    make_log.unlink()
                result = subprocess.run(
                    [
                        BASH,
                        "-lc",
                        f"cd {shlex.quote(git_bash_path(self.workdir))} && "
                        f"PATH={shlex.quote(git_bash_path(self.mock_bin))}:$PATH; export PATH; "
                        f"bash {shlex.quote(git_bash_path(driver))}",
                    ],
                    text=True,
                    capture_output=True,
                    errors="replace",
                    env=env,
                )

                self.assertEqual(
                    result.returncode, 0, f"stdout={result.stdout!r}\nstderr={result.stderr}"
                )
                self.assertTrue(spy_log.is_file())
                self.assertEqual(len(spy_log.read_text().splitlines()), 1)
                actual = spy_log.read_text().rstrip("\n").split("\t")
                self.assertTrue(actual[0].endswith(f"/cache dir/{source}"))
                self.assertEqual(
                    actual[1:],
                    [
                        expected_hash,
                        *CUSTOM_SOURCE_URLS[package],
                    ],
                )
                self.assertEqual(len(make_log.read_text().splitlines()), 1)
                self.assertIn(
                    f"VARS={prefix}_VERSION {prefix}_SOURCE {prefix}_SITE {prefix}_DL_DIR",
                    make_log.read_text(),
                )

    def test_seed_uses_printvars_package_directory(self) -> None:
        functions = self.workdir / "seed-functions.sh"
        functions.write_text(
            "\n".join(
                self.extract_function(name)
                for name in (
                    "rootpxe_build_verified_source_spec",
                    "rootpxe_build_verified_source_metadata",
                    "rootpxe_build_seed_verified_source",
                )
            )
        )
        config = self.workdir / ".config"
        config.write_text("BR2_PACKAGE_CABEXTRACT=y\n")
        driver = self.workdir / "seed-driver.sh"
        driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"source {shlex.quote(git_bash_path(HELPER))}\n"
            f"source {shlex.quote(git_bash_path(functions))}\n"
            "rootpxe_build_verified_source_hash() { :; }\n"
            "download_file_sha256() { : > \"$1\"; }\n"
            "temp_root=$(mktemp -d /tmp/pxeos-cabextract-XXXXXX)\n"
            "cache_dir=\"$temp_root/cache dir/cabextract\"\n"
            "cleanup() {\n"
            "    [[ -d $temp_root ]] || return 0\n"
            "    case $temp_root in /tmp/pxeos-cabextract-*) ;; *) return 1 ;; esac\n"
            "    rm -rf -- \"$temp_root\"\n"
            "}\n"
            "trap cleanup EXIT\n"
            "make() { printf 'CABEXTRACT_VERSION=1.11\\nCABEXTRACT_SOURCE=cabextract-1.11.tar.gz\\nCABEXTRACT_SITE=https://www.cabextract.org.uk\\nCABEXTRACT_DL_DIR=%s' \"$cache_dir\"; }\n"
            "rootpxe_build_seed_verified_source cabextract\n"
            "test -f \"$cache_dir/cabextract-1.11.tar.gz\"\n"
        )
        env = os.environ.copy()
        env.update(
            {
                "MOCK_WGET_LOG": git_bash_path(self.wget_log),
                "MOCK_PAYLOAD": git_bash_path(self.payload),
                "PATH": f"{self.mock_bin}{os.pathsep}{env.get('PATH', '')}",
            }
        )
        command = (
            f"cd {shlex.quote(git_bash_path(self.workdir))} && "
            f"PATH={shlex.quote(git_bash_path(self.mock_bin))}:$PATH; export PATH; "
            f"bash {shlex.quote(git_bash_path(driver))}"
        )
        result = subprocess.run(
            [BASH, "-lc", command], text=True, capture_output=True, errors="replace", env=env
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.wget_urls(), [])

    def test_download_only_make_source_failure_propagates(self) -> None:
        make_log = self.workdir / "make.log"
        (self.mock_bin / "make").write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" >>\"$MOCK_MAKE_LOG\"\n"
            "if [[ $* == *source* && ${MOCK_MAKE_SOURCE_MODE:-success} == fail ]]; then exit 42; fi\n"
            "exit 0\n"
        )
        (self.mock_bin / "make").chmod(0o755)
        function_file = self.workdir / "build-filesystem.sh"
        function_file.write_text(self.extract_function("buildFilesystem"))
        project = self.workdir / "project"
        (project / "Buildroot" / "package").mkdir(parents=True)
        (project / "Buildroot" / "package" / "newConf.in").write_text("")
        (project / "configs").mkdir()
        (project / "configs" / "fsx86.config").write_text("")
        source = self.workdir / "fssourcex86"
        (source / "package").mkdir(parents=True)
        (source / "package" / "Config.in").write_text("")
        (source / "board" / "PXEOS" / "PXEOS" / "rootfs_overlay" / "usr" / "share" / "pxeos" / "lib").mkdir(parents=True)
        (source / "board" / "PXEOS" / "PXEOS" / "rootfs_overlay" / "usr" / "share" / "pxeos" / "lib" / "funcs.sh").write_text("")
        (source / ".config").write_text("")
        driver = self.workdir / "download-only-driver.sh"
        driver.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "dots() { :; }\n"
            "rsync() { :; }\n"
            "rootpxe_build_apply_filesystem_patches() { :; }\n"
            "rootpxe_build_sync_glibc_gconv_config() { :; }\n"
            "rootpxe_build_olddefconfig() { :; }\n"
            "rootpxe_build_normalize_backup_site_config() { :; }\n"
            "rootpxe_build_seed_verified_sources() { :; }\n"
            f"PROJECT_DIRECTORY={shlex.quote(git_bash_path(project))}\n"
            "BUILDROOT_VERSION=2026.02.1\n"
            "fsDownloadOnly=y\n"
            f"source {shlex.quote(git_bash_path(function_file))}\n"
            "export MOCK_MAKE_SOURCE_MODE=fail\n"
            "if buildFilesystem x86; then exit 90; else status=$?; fi\n"
            "[[ $status -eq 1 ]]\n"
            "cd ..\n"
            "export MOCK_MAKE_SOURCE_MODE=success\n"
            "buildFilesystem x86\n"
        )
        env = os.environ.copy()
        env["PATH"] = f"{self.mock_bin}{os.pathsep}{env.get('PATH', '')}"
        env["MOCK_MAKE_LOG"] = git_bash_path(make_log)
        command = (
            f"cd {shlex.quote(git_bash_path(self.workdir))} && "
            f"PATH={shlex.quote(git_bash_path(self.mock_bin))}:$PATH; export PATH; "
            f"bash {shlex.quote(git_bash_path(driver))}"
        )
        result = subprocess.run(
            [BASH, "-lc", command], text=True, capture_output=True, errors="replace", env=env
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(make_log.read_text().splitlines(), ["source", "source"])
        self.assertEqual(result.stdout.count("filesystem packages downloaded. Exiting."), 1)

    def test_existing_symlink_is_rejected_without_network(self) -> None:
        destination = self.workdir / "cache" / self.payload.name
        destination.parent.mkdir()
        target = self.workdir / "target"
        target.write_bytes(b"outside cache")
        try:
            destination.symlink_to(target)
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"symlink creation unavailable: {error}")

        result = self.run_helper(destination, "https://backup.invalid/cabextract.tar.gz")

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(target.read_bytes(), b"outside cache")
        self.assertEqual(self.wget_urls(), [])


if __name__ == "__main__":
    unittest.main()
