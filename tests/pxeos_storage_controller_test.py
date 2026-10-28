"""Storage-only control flow tests; run explicitly by the user, no real NAS."""
from pathlib import Path
import subprocess
import tempfile
import unittest


LIB = Path(__file__).parents[1] / "Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/storage-io.sh"


class StorageControllerTests(unittest.TestCase):
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

    def run_controller(self, script):
        with tempfile.TemporaryDirectory() as directory:
            controller = Path(directory) / "controller.sh"
            controller.write_text(LIB.read_text().replace("/tmp/pxeos.storage-recovery-only", str(Path(directory) / "recovery-only")))
            return subprocess.run(["bash", "-c", 'source "$1"; rootpxe_storage_workspace="$2"; tmp="$2"; storage_test_support="$3"; root="$4"; ' + script,
                                   "storage-test", str(controller), directory,
                                   str(Path(__file__).with_name("storage-test-support.sh")), str(Path(__file__).parents[1])], text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

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
