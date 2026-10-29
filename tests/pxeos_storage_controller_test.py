"""Storage-only control flow tests; run explicitly by the user, no real NAS."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


LIB = Path(__file__).parents[1] / "Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/storage-io.sh"


class StorageControllerTests(unittest.TestCase):
    def test_permanent_storage_rejection_obeys_the_failure_deadline(self):
        result = self.run_controller('''
            set -e
            clock=100
            date() { printf '%s\\n' "$clock"; }
            sleep() { clock=$((clock + $1)); }
            rootpxe_console_message() { :; }
            rootpxe_failure_wait_sec=60 rootpxe_failure_action=shutdown
            rootpxe_storage_stop() { :; }
            rootpxe_storage_call() { return 1; }
            rootpxe_storage_start() { return 1; }
            status=0; rootpxe_storage_recover_until_clean || status=$?
            [[ $status == 2 && $clock == 160 && ${rootpxe_storage_released:-no} != yes ]]
            [[ $(cat "$tmp/failure_action") == shutdown ]]
        ''', timeout=2)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unreachable_error_report_uses_the_same_failure_deadline(self):
        result = self.run_controller('''
            set -e
            clock=100
            date() { printf '%s\\n' "$clock"; }
            sleep() { clock=$((clock + $1)); }
            rootpxe_console_message() { :; }
            rootpxe_require_task_context() { :; }
            rootpxe_bound_callback_message() { printf '%s' "$1"; }
            rootpxe_task_curl() { return 7; }
            rootpxe_failure_wait_sec=60 rootpxe_failure_action=shutdown
            taskid=41 task_token=fixture mac=fixture pxeapi=http://fixture/
            status=0; rootpxe_error_report failure CODE || status=$?
            [[ $status == 2 && $clock == 160 ]]
            [[ $(cat "$tmp/failure_action") == shutdown ]]
        ''', timeout=2)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_permanent_report_rejection_waits_without_resending_or_polling(self):
        for code in (401, 409):
            with self.subTest(code=code):
                result = self.run_controller('''
                    set -e
                    clock=100
                    date() { printf '%s\\n' "$clock"; }
                    sleep() { clock=$((clock + $1)); }
                    rootpxe_require_task_context() { :; }
                    rootpxe_task_console_failure() { :; }
                    rootpxe_bound_callback_message() { printf '%s' "$1"; }
                    rootpxe_error_response_reason() { :; }
                    killStatusReporter() { :; }
                    rootpxe_task_curl() {
                        [[ $* == *'/error'* ]] || { : >"$tmp/unexpected-poll"; exit 91; }
                        printf 'report\\n' >>"$tmp/reports"
                        printf '{"accepted":false}\\n%s' CODE
                    }
                    rootpxe_failure_wait_sec=60 rootpxe_failure_action=shutdown
                    taskid=41 task_token=fixture mac=fixture pxeapi=http://fixture/
                    status=0; rootpxe_error_wait_for_retry failure CODE console_shown || status=$?
                    [[ $status == 2 && $clock == 160 && $(cat "$tmp/reports") == report ]]
                    [[ $(cat "$tmp/failure_action") == shutdown ]]
                    [[ ! -e $tmp/unexpected-poll ]]
                '''.replace("CODE", str(code)), timeout=2)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_unreleased_queued_task_cannot_restart_or_reset_failure_wait(self):
        result = self.run_controller('''
            set -e
            clock=100
            date() { printf '%s\\n' "$clock"; }
            sleep() { clock=$((clock + $1)); }
            rootpxe_require_task_context() { :; }
            killStatusReporter() { :; }
            rootpxe_task_curl() {
                local previous='' timeout=''
                for argument in "$@"; do
                    [[ $previous != --max-time ]] || timeout=$argument
                    previous=$argument
                done
                (( timeout > 0 && timeout <= rootpxe_failure_deadline - clock && timeout <= 20 )) || { : >"$tmp/invalid-budget"; exit 93; }
                printf '{"status":"queued"}'
            }
            rootpxe_storage_reset_retry_state() { exit 92; }
            rootpxe_storage_released=no rootpxe_storage_stopped=yes
            rootpxe_failure_wait_sec=60 rootpxe_failure_action=reboot
            taskid=41 task_token=fixture mac=fixture pxeapi=http://fixture/
            status=0; rootpxe_error_wait_for_retry failure CODE console_shown '{"accepted":true,"waitSec":60}' || status=$?
            [[ $status == 2 && $clock == 160 && $rootpxe_storage_released == no ]]
            [[ ! -e $tmp/invalid-budget ]]
        ''', timeout=2)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_recovery_joins_the_original_helper_and_retains_evidence(self):
        result = self.run_controller('''
            set -e
            clock=100
            date() { printf '%s\\n' "$clock"; }
            sleep() { clock=$((clock + $1)); }
            command sleep 60 & rootpxe_storage_pid=$!
            original_pid=$rootpxe_storage_pid
            trap 'kill -TERM "$original_pid" 2>/dev/null || :; wait "$original_pid" 2>/dev/null || :' EXIT
            printf original >"$tmp/context.json"
            rootpxe_failure_wait_sec=60 rootpxe_failure_action=reboot
            rootpxe_storage_call() { return 1; }
            rootpxe_storage_start() { return 1; }
            status=0; rootpxe_storage_recover_until_clean || status=$?
            [[ $status == 2 && ${rootpxe_storage_stopped:-no} == yes && ${rootpxe_storage_released:-no} != yes ]]
            [[ $(cat "$tmp/context.json") == original ]]
            ! kill -0 "$original_pid" 2>/dev/null
        ''', timeout=2)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_storage_only_download_propagates_failure_timeout(self):
        helpers = re.findall(r"(?ms)^rootpxe_failure_(?:begin|remaining)\(\) \{.*?^\}", LIB.with_name("funcs.sh").read_text())
        overlay = LIB.parents[4]
        for entry in ("pxeos.download",):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                controller = path / "controller.sh"
                controller.write_text(("\n".join(helpers) + "\n" + LIB.read_text())
                                      .replace("/tmp/pxeos.failure_action", str(path / "failure_action")) + '''
                    set -e
                    rootpxe_console_message() { :; }
                    rootpxe_task_log_initialize() { :; }
                    rootpxe_storage_stop() { :; }
                    rootpxe_storage_call() { return 1; }
                    rootpxe_storage_start() { return 1; }
                    clock=100
                    date() { printf '%s\\n' "$clock"; }
                    sleep() { clock=$((clock + $1)); }
                    rootpxe_failure_wait_sec=60 rootpxe_failure_action=shutdown
                ''')
                checkin = path / "checkin.sh"
                checkin.write_text("rootpxe_storage_only=yes\n")
                mount = path / "mount.sh"
                mount.write_text(":\n")
                prefix = (overlay / "bin" / entry).read_text().split("\nfi", 1)[0] + "\nfi\nexit 99\n"
                prefix = prefix.replace("/usr/share/pxeos/lib/funcs.sh", str(controller))
                prefix = prefix.replace("/bin/pxeos.checkin", str(checkin)).replace("/bin/pxeos.mount", str(mount))
                script = path / entry
                script.write_text(prefix)
                result = subprocess.run(["bash", str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, timeout=2, check=False)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual((path / "failure_action").read_text().strip(), "shutdown")

    def test_first_acknowledgement_updates_policy_without_moving_failure_start(self):
        result = self.run_controller('''
            set -e
            clock=100
            date() { printf '%s\\n' "$clock"; }
            rootpxe_failure_wait_sec=120 rootpxe_failure_action=shutdown
            rootpxe_failure_begin
            clock=110
            rootpxe_failure_begin '{"waitSec":60,"failureAction":"reboot"}'
            clock=120
            rootpxe_failure_begin '{"waitSec":3600,"failureAction":"shutdown"}'
            [[ $rootpxe_failure_started_at == 100 && $rootpxe_failure_deadline == 160 && $rootpxe_failure_action == reboot ]]
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_storage_api_caps_request_timeout_and_never_sends_zero(self):
        result = self.run_controller('''
            set -e
            clock=100
            date() { printf '%s\\n' "$clock"; }
            rootpxe_failure_deadline=102
            rootpxe_task_curl() { printf '%s\\n' "$@" >"$tmp/request"; printf '{"success":true}\\n200'; }
            taskid=41 task_token=fixture mac=fixture progress_attempt=2
            rootpxe_storage_nonce=fixture rootpxe_storage_worker_nonce=fixture pxeapi=http://fixture/
            rootpxe_storage_call release >/dev/null
            [[ $(sed -n '/--max-time/{n;p;}' "$tmp/request") == 2 ]]
            clock=102
            status=0; rootpxe_storage_call release || status=$?
            [[ $status == 2 ]]
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_storage_only_marker_skips_power_only_after_success(self):
        overlay = LIB.parents[4]
        source = (overlay / "etc/init.d/S99pxeos").read_text()
        for status, action in ((0, "shutdown"), (2, "shutdown"), (2, "reboot")):
            with self.subTest(status=status, action=action), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)
                (path / "recovery-only").touch()
                (path / "failure_action").write_text(action)
                script = path / "S99pxeos"
                script.write_text(source.replace("/tmp/pxeos.storage-recovery-only", str(path / "recovery-only"))
                                  .replace("/tmp/pxeos.failure_action", str(path / "failure_action")))
                result = subprocess.run(["bash", "-c", '''
                    set -e
                    POWER_TRACE=$3; export POWER_TRACE
                    poweroff() { printf 'ACTION shutdown\\n' >>"$POWER_TRACE"; }
                    reboot() { printf 'ACTION reboot\\n' >>"$POWER_TRACE"; }
                    export -f poweroff reboot
                    PXEOS_STATUS=$2; export PXEOS_STATUS
                    pxeos() { return "$PXEOS_STATUS"; }; export -f pxeos
                    mdraid=false isdebug='' mode='' bash "$1"
                ''', "storage-only-test", str(script), str(status), str(path / "power.trace")], text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                actions = (path / "power.trace").read_text().splitlines() if (path / "power.trace").exists() else []
                self.assertEqual(actions, [] if status == 0 else ["ACTION " + action])

    def test_completed_capture_recovery_outweighs_earlier_error_rejection(self):
        result = self.run_controller('''
            rootpxe_storage_quiesce() { :; }
            rootpxe_error_report() { rootpxe_error_report_response=''; return 1; }
            rootpxe_storage_call() { return 1; }
            rootpxe_storage_recover_until_clean() { rootpxe_storage_recovery_completed=yes; }
            : >"$tmp/ready.json"
            rootpxe_storage_failure_cleanup failure
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_lost_release_ack_does_not_restart_helper_or_preflight(self):
        result = self.run_controller('''
            rootpxe_storage_stop() { printf 'stop\\n' >>"$tmp/events"; }
            rootpxe_storage_call() { [[ $1 == release ]] || exit 86; printf 'release\\n' >>"$tmp/events"; }
            rootpxe_storage_start() { printf 'unexpected helper restart\\n' >&2; exit 88; }
            rootpxe_storage_released=no
            rootpxe_storage_recover_until_clean
            [[ $rootpxe_storage_released == yes && $(cat "$tmp/events") == $'stop\\nrelease' ]]
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unclean_release_still_uses_original_recovery(self):
        result = self.run_controller('''
            rootpxe_storage_stop() { printf 'stop\\n' >>"$tmp/events"; }
            rootpxe_storage_call() { [[ $1 == release ]] || exit 86; printf 'release-rejected\\n' >>"$tmp/events"; return 1; }
            rootpxe_storage_start() { printf 'start\\n' >>"$tmp/events"; }
            rootpxe_storage_recover_once() { printf 'recover\\n' >>"$tmp/events"; rootpxe_storage_released=yes; }
            rootpxe_storage_released=no
            rootpxe_storage_recover_until_clean
            [[ $(cat "$tmp/events") == $'stop\\nrelease-rejected\\nstart\\nrecover' ]]
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_controller(self, script, timeout=None):
        with tempfile.TemporaryDirectory() as directory:
            controller = Path(directory) / "controller.sh"
            functions = LIB.with_name("funcs.sh").read_text()
            selected = re.findall(r"(?ms)^rootpxe_failure_(?:begin|remaining)\(\) \{.*?^\}", functions)
            selected += re.findall(r"(?ms)^rootpxe_error_report\(\) \{.*?^\}", functions)
            selected += re.findall(r"(?ms)^rootpxe_error_wait_for_retry\(\) \{.*?^\}", functions)
            source = "\n".join(selected) + "\n" + LIB.read_text()
            controller.write_text(source.replace("/tmp/pxeos.storage-recovery-only", str(Path(directory) / "recovery-only"))
                                  .replace("/tmp/pxeos.failure_action", str(Path(directory) / "failure_action")))
            return subprocess.run(["bash", "-c", 'source "$1"; rootpxe_console_message() { :; }; rootpxe_storage_workspace="$2"; tmp="$2"; storage_test_support="$3"; root="$4"; ' + script,
                                   "storage-test", str(controller), directory,
                                   str(Path(__file__).with_name("storage-test-support.sh")), str(Path(__file__).parents[1])], text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=timeout)

    def test_smb_mount_waits_for_the_real_child_and_preserves_failure(self):
        result = self.run_controller('''
            mount.cifs() { printf joined >"$rootpxe_storage_workspace/mount-ended"; return 17; }
            result=0
            rootpxe_storage_mount_smb //fixture/share /storage -o ro || result=$?
            [[ $result -eq 17 && -f $rootpxe_storage_workspace/mount-ended ]]
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_smb_mount_cancellation_joins_child_before_return(self):
        result = self.run_controller('''
            export rootpxe_storage_workspace
            mount.cifs() {
                exec python3 -c 'import os, pathlib, signal, sys, time; p=pathlib.Path(os.environ["rootpxe_storage_workspace"]); signal.signal(signal.SIGTERM, lambda *_: sys.exit(23)); (p/"supervisor-pid").write_text(str(os.getppid())); (p/"mount-pid").write_text(str(os.getpid())); time.sleep(60)'
            }
            rootpxe_storage_mount_smb //fixture/share /storage -o ro & controller=$!
            for _ in {1..100}; do [[ ! -f $rootpxe_storage_workspace/mount-pid ]] || break; sleep .01; done
            [[ -f $rootpxe_storage_workspace/mount-pid ]] || exit 81
            child=$(cat "$rootpxe_storage_workspace/mount-pid")
            supervisor=$(cat "$rootpxe_storage_workspace/supervisor-pid")
            [[ $supervisor =~ ^[1-9][0-9]*$ && $supervisor != "$child" ]] || exit 83
            # Bash adds a launcher when a () function is backgrounded. The
            # mount child's PPID identifies the process that installed traps.
            [[ $(ps -o ppid= -p "$child" | tr -d ' ') == "$supervisor" ]] || exit 84
            kill -TERM "$supervisor"
            status=0; wait "$controller" || status=$?
            [[ $status -ne 0 ]] || exit 82
            ! kill -0 "$child" 2>/dev/null
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_original_writer_failure_prevents_publish(self):
        result = self.run_controller('''
            type=up
            rootpxe_wait_for_writers() { return 9; }
            rootpxe_storage_call() { printf 'unexpected publish\\n'; return 0; }
            rootpxe_finalize_capture
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unexpected publish", result.stdout)

    def test_native_result_stays_a_pipe_when_caller_discards_stdout(self):
        result = self.run_controller('''
            printf '%s' '{}' >"$rootpxe_storage_workspace/context.json"
            rootpxe_storage_helper="$rootpxe_storage_workspace/native-fixture"
            cat >"$rootpxe_storage_helper" <<'HELPER'
#!/usr/bin/env python3
import os, stat
assert stat.S_ISFIFO(os.fstat(6).st_mode)
os.write(6, b'{"event":"mount","mounted":true,"errno":0}\\n')
HELPER
            chmod 700 "$rootpxe_storage_helper"
            rootpxe_storage_native mount-nfs >/dev/null
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_recovery_cleans_only_owned_stage_before_claim(self):
        result = self.run_controller('''
            rootpxe_storage_stage=dev/27/2
            rootpxe_storage_lock=.locks/key
            rootpxe_storage_owned() { printf '%s' '{"owned":[{"path":"dev/27/2/payload/data","kind":"file"},{"path":"dev/27/2/payload","kind":"dir"},{"path":"dev/27/2","kind":"dir"},{"path":".locks/key/owner","kind":"file"},{"path":".locks/key","kind":"dir"},{"path":"dev/27/1/unknown","kind":"file"}]}'; }
            rootpxe_storage_exec() { printf '%s\\n' "$2"; }
            rootpxe_storage_cleanup_owned
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["dev/27/2/payload/data", "dev/27/2/payload",
                                                     "dev/27/2", ".locks/key/owner", ".locks/key"])

    def test_recovery_never_reconstructs_finish_from_disk(self):
        result = self.run_controller('''
            mkdir "$rootpxe_storage_workspace/image"
            printf '%s' '{"finish":{"sizeBytes":"12","partitionInventory":{"version":1},"originalSchema":null,"digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' >"$rootpxe_storage_workspace/preflight.json"
            rootpxe_build_partition_inventory() { printf 'disk probe forbidden\\n'; return 99; }
            rootpxe_task_curl() { printf '%s\\n' "$@" >"$rootpxe_storage_workspace/args"; printf '%s' '{"success":true}'; }
            rootpxe_storage_finish_original
            grep -Fx 'sizeBytes=12' "$rootpxe_storage_workspace/args"
            grep -Fx '{"version":1}' "$rootpxe_storage_workspace/frozen-inventory.json"
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("disk probe forbidden", result.stdout)

    def test_context_requires_original_owner_attempt_identity_and_capabilities(self):
        result = self.run_controller('''
            set -e
            . "$storage_test_support"
            storage_test_load
            unset rootpxe_storage_workspace
            taskid=27 taskType=capture progress_attempt=2
            document=$(storage_test_context_json '{"taskId":27,"type":"capture","progressAttempt":2,"protocol":"nfs","storageip":"fixture.invalid","exportPath":"/images"}')
            rootpxe_storage_apply_context "$document"
            original=$(cat "$rootpxe_storage_workspace/context.json")
            for change in '.storageAccess.execution.taskId="28"' '.storageAccess.execution.taskType="deploy"' '.storageAccess.execution.executionAttempt=1' '.storageAccess.nfsUid=-1' '.storageAccess.nfsGid=4294967295' '.storageAccess.nfsVersion="4"' 'del(.storageAccess.execution.nonce)'; do
                changed=$(jq -c "$change" <<<"$document")
                if rootpxe_storage_apply_context "$changed"; then exit 81; fi
                [[ $(cat "$rootpxe_storage_workspace/context.json") == "$original" ]] || exit 82
            done
            cat >"$rootpxe_storage_helper" <<'BAD_CAPABILITIES'
#!/bin/sh
printf '%s\\n' '{"version":1,"helper":true,"numericIdentity":false,"durablePublish":true}'
BAD_CAPABILITIES
            if rootpxe_storage_apply_context "$document"; then exit 83; fi
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_finalize_preserves_every_failure_before_publication_ack(self):
        for fault in ("none", "writer", "metadata", "seal", "empty", "begin", "old-rename", "new-rename", "complete"):
            with self.subTest(fault=fault):
                result = self.run_controller('''
                    type=up img=images/image rootpxe_storage_stage=dev/27/2
                    printf '{}' >"$rootpxe_storage_workspace/inventory"
                    rootpxe_partition_inventory_file="$rootpxe_storage_workspace/inventory"
                    printf '%s' '{"targetExists":true}' >"$rootpxe_storage_workspace/preflight.json"
                    rootpxe_wait_for_writers() { echo writer >>"$tmp/events"; [[ $fault != writer ]]; }
                    rootpxe_storage_sync_metadata() { echo metadata >>"$tmp/events"; [[ $fault != metadata ]]; }
                    rootpxe_directory_size_bytes() { [[ $fault != empty ]] && echo 12 || echo 0; }
                    rootpxe_storage_call() { echo "$1" >>"$tmp/events"; [[ $fault != begin || $1 != publish-begin ]] && [[ $fault != complete || $1 != publish-complete ]]; }
                    rootpxe_storage_exec() {
                        echo "$1:$2${3:+:$3}" >>"$tmp/events"
                        [[ $fault != seal || $1 != seal ]] &&
                        [[ $fault != old-rename || $1 != rename-owned || $2 != images/image ]] &&
                        [[ $fault != new-rename || $1 != rename-owned || $2 != dev/27/2/payload ]]
                    }
                    fault=''' + fault + '''
                    status=0; rootpxe_finalize_capture || status=$?
                    cat "$tmp/events"
                    exit "$status"
                ''')
                trace = result.stdout.splitlines()
                if fault == "none":
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(trace, ["writer", "metadata", "seal:dev/27/2/payload", "publish-begin", "rename-owned:images/image:dev/27/2/previous", "rename-owned:dev/27/2/payload:images/image", "publish-complete"])
                else:
                    self.assertNotEqual(result.returncode, 0)
                    if fault != "complete":
                        self.assertNotIn("publish-complete", trace)
                    if fault in ("writer", "metadata", "seal", "empty", "begin"):
                        self.assertFalse(any(line.startswith("rename-owned:") for line in trace))
                self.assertFalse(any("remove-owned" in line or line == "release" for line in trace))

    def test_completed_recovery_cleans_owned_scope_and_joins_before_release(self):
        for fault in ("none", "remove", "stop"):
            with self.subTest(fault=fault):
                result = self.run_controller('''
                    taskType=capture rootpxe_storage_stage=dev/27/2 rootpxe_storage_lock=.locks/key
                    fixture_response='{"recoveryDisposition":"completed","owned":[{"path":"dev/27/2/payload/a","kind":"file"},{"path":"dev/27/2","kind":"dir"},{"path":"dev/27/1/unknown","kind":"file"},{"path":".locks/other/owner","kind":"file"}]}'
                    rootpxe_storage_owned() { printf '%s' "$fixture_response"; }
                    rootpxe_storage_exec() { echo "$1:$2" >>"$tmp/events"; [[ $fault != remove ]]; }
                    rootpxe_storage_stop() { echo joined >>"$tmp/events"; [[ $fault != stop ]]; }
                    rootpxe_storage_call() { echo "$1:$*" >>"$tmp/events"; }
                    fault=''' + fault + '''
                    status=0; rootpxe_storage_recover_once || status=$?
                    cat "$tmp/events"
                    exit "$status"
                ''')
                trace = result.stdout.splitlines()
                self.assertFalse(any("dev/27/1" in line or ".locks/other" in line for line in trace))
                if fault == "none":
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertLess(trace.index("joined"), next(i for i, line in enumerate(trace) if line.startswith("release:")))
                    self.assertIn("workerStopped=true", trace[-1])
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(any(line.startswith("release:") for line in trace))

    def test_read_recovery_requires_no_remote_write(self):
        result = self.run_controller('''
            taskType=deploy
            rootpxe_storage_owned() { printf '%s' '{"recoveryDisposition":"read","owned":[]}'; }
            rootpxe_storage_exec() { echo unexpected-write >>"$tmp/events"; return 81; }
            rootpxe_storage_stop() { echo joined >>"$tmp/events"; }
            rootpxe_storage_call() { echo "$1" >>"$tmp/events"; }
            status=0; rootpxe_storage_recover_once || status=$?
            cat "$tmp/events"
            exit "$status"
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["joined", "release"])

    def test_recovery_publish_reads_original_files_before_rename_and_frozen_finish(self):
        for fail_read in (False, True):
            with self.subTest(fail_read=fail_read):
                result = self.run_controller('''
                    taskType=capture img=images/image rootpxe_storage_stage=dev/27/2 rootpxe_storage_lock=.locks/key
                    fixture_response='{"recoveryDisposition":"publish","targetExists":true,"owned":[{"path":"dev/27/2/payload","kind":"dir"},{"path":"dev/27/2/payload/a","kind":"file"}],"finish":{"sizeBytes":"12","partitionInventory":{"version":1},"originalSchema":null,"digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
                    rootpxe_storage_owned() { printf '%s' "$fixture_response"; }
                    rootpxe_storage_change_direction() { echo "direction:$1" >>"$tmp/events"; }
                    rootpxe_storage_exec() { echo "$1:$2${3:+:$3}" >>"$tmp/events"; [[ $fail_read != yes || $1 != read ]]; }
                    rootpxe_storage_call() { echo "$1" >>"$tmp/events"; }
                    rootpxe_task_curl() { echo frozen-finish >>"$tmp/events"; printf '{"success":true}'; }
                    rootpxe_build_partition_inventory() { echo unexpected-disk >>"$tmp/events"; return 82; }
                    rootpxe_storage_cleanup_owned() { echo cleanup >>"$tmp/events"; }
                    rootpxe_storage_stop() { echo joined >>"$tmp/events"; }
                    taskid=27 task_token=fixture mac=fixture web=http://fixture.invalid/
                    fail_read=''' + ("yes" if fail_read else "no") + '''
                    status=0; rootpxe_storage_recover_once || status=$?
                    cat "$tmp/events"
                    exit "$status"
                ''')
                trace = result.stdout.splitlines()
                if fail_read:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(trace, ["direction:read", "read:dev/27/2/payload/a:-"])
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(trace, ["direction:read", "read:dev/27/2/payload/a:-", "direction:write", "rename-owned:images/image:dev/27/2/previous", "rename-owned:dev/27/2/payload:images/image", "publish-complete", "frozen-finish", "cleanup", "joined", "release"])

    def test_rollback_failure_never_cleans_or_releases_unknown_state(self):
        for fail_rename in (False, True):
            with self.subTest(fail_rename=fail_rename):
                result = self.run_controller('''
                    taskType=capture img=images/image rootpxe_storage_stage=dev/27/2
                    printf '{"direction":"write"}' >"$tmp/context.json"
                    rootpxe_storage_owned() { printf '%s' '{"recoveryDisposition":"rollback","owned":[{"path":"images/image","kind":"dir"},{"path":"dev/27/2/previous","kind":"dir"}]}'; }
                    rootpxe_storage_exec() { echo "$1:$2:$3" >>"$tmp/events"; [[ $fail_rename != yes ]]; }
                    rootpxe_storage_cleanup_owned() { echo cleanup >>"$tmp/events"; }
                    rootpxe_storage_stop() { echo joined >>"$tmp/events"; }
                    rootpxe_storage_call() { echo "$1" >>"$tmp/events"; }
                    fail_rename=''' + ("yes" if fail_rename else "no") + '''
                    status=0; rootpxe_storage_recover_once || status=$?
                    cat "$tmp/events"
                    exit "$status"
                ''')
                trace = result.stdout.splitlines()
                if fail_rename:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(trace, ["rename-owned:images/image:dev/27/2/payload"])
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(trace, ["rename-owned:images/image:dev/27/2/payload", "rename-owned:dev/27/2/previous:images/image", "cleanup", "joined", "release"])

    def test_marker_or_directory_name_cannot_adopt_a_published_execution(self):
        result = self.run_controller('''
            mkdir "$tmp/image"
            printf '27\\n' >"$tmp/image/.rootpxe-capture-taskid"
            if rootpxe_capture_resume_published; then exit 81; fi
            rootpxe_storage_published=yes
            rootpxe_capture_resume_published
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unknown_or_unconfirmed_recovery_never_mutates_or_releases(self):
        for disposition in ("unavailable", "unknown"):
            with self.subTest(disposition=disposition):
                result = self.run_controller('''
                    taskType=capture
                    rootpxe_storage_owned() {
                        [[ $fixture_disposition != unavailable ]] || return 81
                        printf '%s' '{"recoveryDisposition":"unknown","owned":[]}'
                    }
                    rootpxe_storage_exec() { echo unexpected-mutation; }
                    rootpxe_storage_cleanup_owned() { echo unexpected-cleanup; }
                    rootpxe_storage_stop() { echo unexpected-stop; }
                    rootpxe_storage_call() { echo unexpected-release; }
                    fixture_disposition=''' + disposition + '''
                    rootpxe_storage_recover_once
                ''')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_finish_without_original_digest_never_probes_disk_or_claims_success(self):
        result = self.run_controller('''
            printf '%s' '{"finish":{"sizeBytes":"12","partitionInventory":{"version":1}}}' >"$tmp/preflight.json"
            rootpxe_build_partition_inventory() { echo unexpected-disk; return 81; }
            rootpxe_task_curl() { echo unexpected-finish; return 82; }
            rootpxe_storage_finish_original
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_payload_outside_original_shadow_stops_before_helper_command(self):
        result = self.run_controller('''
            rootpxe_storage_stage=dev/27/2
            rootpxe_storage_exec() { echo unexpected-command; return 81; }
            rootpxe_storage_ensure_parents() { echo unexpected-parent; return 82; }
            rootpxe_storage_write_payload "$tmp/foreign" 0 && exit 83
            rootpxe_storage_read_files "$tmp/foreign" && exit 84
            exit 0
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
