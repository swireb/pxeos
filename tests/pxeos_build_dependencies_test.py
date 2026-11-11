import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ARM_PACKAGE = "gcc-aarch64-linux-gnu"
APT_ERROR = "Temporary failure resolving 'azure.archive.ubuntu.com'"
MOCKS = r'''
grep() {
    if [[ $# == 2 && $1 == '^ID=' && $2 == /etc/os-release ]]; then
        printf 'ID="%s"\n' "$MOCK_DISTRO"
    else
        command grep "$@"
    fi
}
dpkg-query() {
    printf 'installed\t%s:amd64\n' $MOCK_INSTALLED
}
rpm() {
    printf '%s\n' $MOCK_INSTALLED
}
sudo() {
    printf '%s\n' "$*" >> "$MOCK_LOG"
    case "$1" in
        apt|apt-get)
            if [[ ${!#} == update ]]; then
                if [[ $MOCK_INSTALL_RESULT == update-fails ]]; then
                    echo 'mock index refresh failed' >&2
                    return 100
                fi
            elif [[ $MOCK_INSTALL_RESULT != success ]] &&
                { [[ $MOCK_INSTALL_RESULT != recovers ]] || ! command grep -q ' update$' "$MOCK_LOG"; }; then
                printf '%s\n' "$MOCK_APT_ERROR" >&2
                return 100
            fi
            ;;
        dnf) [[ $MOCK_INSTALL_RESULT == success ]] ;;
        *) return 97 ;;
    esac
}
'''
COMMON = "wget tar git make gcc flex bison cpio file rsync patch unzip bzip2 findutils autoconf libtool autopoint"
DEB = COMMON + " libelf-dev xz-utils g++ libncurses-dev"
RPM = COMMON + " elfutils-libelf-devel perl xz gcc-c++ ncurses-devel"


class BuildDependenciesTest(unittest.TestCase):
    def run_build(self, *args, distro="ubuntu", installed=DEB, outcome="success"):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            mock = work / "mocks.bash"
            mock.write_text(MOCKS)
            log = work / "package-manager.log"
            result = subprocess.run(
                ["bash", str(ROOT / "build.sh"), "-n", "--server-version", "1.0.0",
                 "--path", str(work / "unreachable-build-directory"), *args],
                env={**os.environ, "BASH_ENV": str(mock), "MOCK_LOG": str(log),
                     "MOCK_DISTRO": distro, "MOCK_INSTALLED": installed,
                     "MOCK_INSTALL_RESULT": outcome, "MOCK_APT_ERROR": APT_ERROR,
                     "PXEOS_BUILD_VERSION": "Local-261111-0100", "GITHUB_ACTIONS": "false"},
                text=True, capture_output=True, check=False,
            )
            return result, log.read_text().splitlines() if log.exists() else []

    def assert_passed_dependencies(self, result):
        self.assertIn("unreachable-build-directory", result.stderr)

    def test_only_actual_arm64_builds_require_cross_compiler(self):
        for args in [("-a", "x86"), ("-a", "x64"), ("--fs-download-only",),
                     ("--fs-download-only", "-a", "arm64")]:
            with self.subTest(args=args):
                result, calls = self.run_build("-i", *args)
                self.assert_passed_dependencies(result)
                self.assertEqual(calls, [])
        for args in [(), ("-k", "-a", "arm64"), ("-f", "-a", "arm64")]:
            with self.subTest(args=args):
                result, calls = self.run_build("-i", *args)
                self.assert_passed_dependencies(result)
                self.assertEqual(len(calls), 1)
                self.assertTrue(calls[0].endswith(" install -y " + ARM_PACKAGE), calls)

        result, calls = self.run_build("-i", "-a", "x86", installed=DEB.replace(" autopoint", ""))
        self.assert_passed_dependencies(result)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].endswith(" install -y autopoint"), calls)

    def test_source_download_configs_use_internal_toolchains(self):
        for arch in ("x86", "x64", "arm64"):
            with self.subTest(arch=arch):
                config = (ROOT / "configs" / f"fs{arch}.config").read_text().splitlines()
                self.assertIn("BR2_TOOLCHAIN_BUILDROOT=y", config)
                self.assertNotIn("BR2_TOOLCHAIN_EXTERNAL=y", config)

    def test_automatic_install_requires_flag(self):
        result, calls = self.run_build("-a", "arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--install-dep", result.stdout)
        self.assertNotIn("unreachable-build-directory", result.stderr)
        self.assertEqual(calls, [])

    def test_apt_refreshes_once_after_failed_install(self):
        for outcome in ("recovers", "update-fails", "install-fails"):
            with self.subTest(outcome=outcome):
                distro = "debian" if outcome == "recovers" else "ubuntu"
                result, calls = self.run_build("-i", "-a", "arm64", distro=distro, outcome=outcome)
                self.assertIn(APT_ERROR, result.stderr)
                self.assertEqual(len(calls), 2 if outcome == "update-fails" else 3, calls)
                self.assertTrue(calls[0].startswith("apt-get -o Acquire::Retries="), calls)
                self.assertTrue(calls[0].endswith(" install -y " + ARM_PACKAGE), calls)
                self.assertTrue(calls[1].endswith(" --error-on=any update"), calls)
                if outcome != "update-fails":
                    self.assertEqual(calls[0], calls[2])
                if outcome == "recovers":
                    self.assert_passed_dependencies(result)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("unreachable-build-directory", result.stderr)
                    self.assertIn("DNS", result.stderr)
                if outcome == "update-fails":
                    self.assertIn("mock index refresh failed", result.stderr)

    def test_dnf_keeps_its_own_install_path(self):
        result, calls = self.run_build("-i", "-a", "arm64", distro="rocky",
                                       installed=RPM, outcome="install-fails")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EPEL", result.stdout)
        self.assertEqual(calls, ["dnf install -y " + ARM_PACKAGE])

        result, calls = self.run_build("-i", "-a", "x64", distro="rocky", installed=RPM)
        self.assert_passed_dependencies(result)
        self.assertNotIn("EPEL", result.stdout)
        self.assertEqual(calls, [])

        result, calls = self.run_build("-i", "-a", "arm64", distro="rocky",
                                       installed=f"{RPM} {ARM_PACKAGE}")
        self.assert_passed_dependencies(result)
        self.assertNotIn("EPEL", result.stdout)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
