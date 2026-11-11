import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ".github/scripts/prepare-ubuntu-apt.sh"
MIRROR_LIST = "mirror+file:/etc/apt/apt-mirrors.txt"
ARCHIVE = "https://archive.ubuntu.com/ubuntu/"
SOURCE = f"""# {MIRROR_LIST}
Types: deb
URIs: {MIRROR_LIST}
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
"""
MOCK = r'''
sudo() {
    printf '%s\n' "$*" >> "$APT_LOG"
    case "$1" in
        tee)
            [[ $2 == "$MOCK_SOURCE" ]] || return 98
            [[ $FAIL_COMMAND != tee ]] || return 23
            command tee "$2"
            ;;
        apt-get)
            [[ $FAIL_COMMAND != apt-get ]] || return 100
            ;;
        *) return 97 ;;
    esac
}
'''


class CiAptTest(unittest.TestCase):
    def run_script(self, original, fail_command=""):
        with tempfile.TemporaryDirectory() as tmpdir:
            work = Path(tmpdir)
            source = work / "ubuntu.sources"
            if original is not None:
                source.write_text(original)
            other = work / "microsoft.sources"
            other.write_text("URIs: https://packages.microsoft.com/repos/azure-cli/\n")
            mock = work / "sudo.bash"
            mock.write_text(MOCK)
            log = work / "sudo.log"
            result = subprocess.run(
                ["bash", str(ROOT / SCRIPT), str(source)],
                env={**os.environ, "BASH_ENV": str(mock), "APT_LOG": str(log),
                     "MOCK_SOURCE": str(source), "FAIL_COMMAND": fail_command},
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(other.read_text(), "URIs: https://packages.microsoft.com/repos/azure-cli/\n")
            return result, source.read_text() if source.exists() else None, (
                log.read_text().splitlines() if log.exists() else []
            )

    def test_replaces_only_ubuntu_uri_and_refreshes_index(self):
        result, updated, calls = self.run_script(SOURCE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(updated, SOURCE.replace(f"URIs: {MIRROR_LIST}", f"URIs: {ARCHIVE}"))
        self.assertIn(ARCHIVE, result.stdout)
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].startswith("tee "), calls)
        self.assertEqual(calls[1], "apt-get --error-on=any update")

    def test_no_exact_mirror_uri_leaves_runner_sources_alone(self):
        for source in (None, SOURCE.replace(f"URIs: {MIRROR_LIST}", f"URIs: {MIRROR_LIST}.bak"),
                       SOURCE.replace(f"URIs: {MIRROR_LIST}", f"URIs: {ARCHIVE}")):
            with self.subTest(source=source):
                result, updated, calls = self.run_script(source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(updated, source)
                self.assertEqual(calls, [])

    def test_reports_write_and_update_failures(self):
        for fail_command, exit_code, call_count in (("tee", 23, 1), ("apt-get", 100, 2)):
            with self.subTest(fail_command=fail_command):
                result, _, calls = self.run_script(SOURCE, fail_command)
                self.assertEqual(result.returncode, exit_code, result.stderr)
                self.assertEqual(len(calls), call_count)

    def test_both_workflows_initialize_every_build_job(self):
        for name in ("release", "beta"):
            workflow = (ROOT / ".github/workflows" / f"{name}.yml").read_text()
            jobs = re.split(r"\n(?=  \w+:\n)", workflow.split("\njobs:", 1)[1])
            build_jobs = [job for job in jobs if "run: ./build.sh " in job]
            with self.subTest(workflow=name):
                self.assertEqual(len(build_jobs), 7)
                self.assertEqual(workflow.count(f"run: bash {SCRIPT}"), 7)
                for job in build_jobs:
                    self.assertIn("runs-on: ubuntu-24.04", job)
                    self.assertLess(job.index("uses: actions/checkout@v6"),
                                    job.index(f"run: bash {SCRIPT}"))
                    self.assertLess(job.index(f"run: bash {SCRIPT}"),
                                    job.index("run: ./build.sh "))


if __name__ == "__main__":
    unittest.main()
