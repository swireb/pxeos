#!/usr/bin/env bash
# Offline disk-permit contract.  It extracts only permit helpers and replaces
# curl/sleep/error reporting; it never sources or runs a PXEOS top-level script.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect_status() {
    local expected="$1" actual
    shift
    set +e
    "$@" >"$tmp/out" 2>&1
    actual=$?
    set -e
    [[ $actual -eq $expected ]] || fail "expected status $expected, got $actual: $(<"$tmp/out")"
}

# Keep the harness isolated from the rest of funcs.sh, whose top-level state
# and hardware helpers are deliberately not suitable for host execution.
awk '/^rootpxe_request_disk_permit\(\)/ { copy = 1 } /^rootpxe_error_wait_for_retry\(\)/ { exit } copy' "$funcs" >"$tmp/permit.sh"

# PXEOS carries jq, while the host Git Bash used by this offline harness does
# not.  This controlled substitute accepts only the JSON fields below.  It is
# not a jq integration test: it preserves jq -e false status and typed boolean
# behavior so the permit contract cannot accidentally depend on mock leniency.
jq() {
    local args="$*" arg has_e=0 input value
    for arg in "$@"; do
        [[ $arg == -* && $arg == *e* ]] && has_e=1
    done
    input=$(cat)
    [[ $input == \{*\} ]] || return 1
    if [[ $args == *'.granted'* ]]; then
        [[ $input =~ \"granted\"[[:space:]]*:[[:space:]]*(true|false) ]] || return 1
        value=${BASH_REMATCH[1]}
        printf '%s\n' "$value"
        [[ $has_e -eq 1 && $value == false ]] && return 1
        return 0
    fi
    if [[ $args == *'.targetId'* ]]; then
        [[ $input =~ \"targetId\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || return 1
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ $args == *'.operation'* ]]; then
        [[ $input =~ \"operation\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || return 1
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ $args == *'.code'* ]]; then
        [[ $input =~ \"code\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || return 1
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ $args == *'.status'* ]]; then
        [[ $input =~ \"status\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || return 1
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 0
}

if jq -er '.granted // false' <<< '{"granted":false}' >/dev/null; then
    fail 'jq mock must preserve jq -e false status'
fi
[[ $(jq -r 'if (.granted | type) == "boolean" then .granted else error("invalid") end' <<< '{"granted":false}') == false ]] || fail 'jq mock must accept boolean false without -e'
if jq -r 'if (.granted | type) == "boolean" then .granted else error("invalid") end' <<< '{"granted":"true"}' >/dev/null; then
    fail 'jq mock must reject string true for typed boolean filter'
fi

run_request() {
    local permit_response="$1" status_response="$2"
    taskid=7 task_token='test-token-0123456789' mac='00:0c:29:ae:cc:4f'
    pxeapi='https://rootpxe.invalid/api/'
    curl() {
        case " $* " in
            *disk-permit*) [[ $permit_response == __CURL_TRANSPORT_FAILURE__ ]] && return 7; printf '%s' "$permit_response" ;;
            *task-status*) [[ $status_response == __CURL_TRANSPORT_FAILURE__ ]] && return 7; printf '%s' "$status_response" ;;
            *) return 1 ;;
        esac
    }
    sleep() { :; }
    rootpxe_require_task_context() { return 0; }
    . "$tmp/permit.sh"
    rootpxe_request_disk_permit_for_target 'disk-serial-1' 'deploy_write'
}

success=$'{"granted":true,"targetId":"disk-serial-1","operation":"deploy_write"}\n200'
false_200=$'{"granted":false,"code":"DISK_PERMIT_TASK_REJECTED"}\n200'
string_true=$'{"granted":"true","targetId":"disk-serial-1","operation":"deploy_write"}\n200'
invalid_json=$'not-json\n200'
wrong_target=$'{"granted":true,"targetId":"other-disk","operation":"deploy_write"}\n200'
wrong_operation=$'{"granted":true,"targetId":"disk-serial-1","operation":"capture_read_write"}\n200'
bad_request=$'{"error":"bad","code":"DISK_PERMIT_INVALID_TARGET"}\n400'
forbidden=$'{"error":"forbidden","code":"DISK_PERMIT_TASK_REJECTED"}\n403'
conflict=$'{"error":"conflict","code":"DISK_PERMIT_BINDING_CONFLICT"}\n409'
missing=$'<html>not found</html>\n404'
server_error=$'{"error":"temporary"}\n500'
transport_failure='__CURL_TRANSPORT_FAILURE__'
cancelled=$'{"status":"cancelled"}\n200'
superseded=$'{"status":"superseded"}\n200'
deleted_404=$'{"status":"deleted"}\n404'
running=$'{"status":"running"}\n200'
html_404=$'<html>not found</html>\n404'
unauthorized=$'{"error":"unauthorized"}\n401'
unknown_code=$'{"error":"do-not-show","code":"DISK_PERMIT_UNRECOGNIZED"}\n403'

# Red/green behavioral matrix: only task-status JSON confirmation may return 10.
expect_status 0 run_request "$success" "$running"
expect_status 12 run_request "$false_200" "$running"
expect_status 10 run_request "$false_200" "$cancelled"
expect_status 12 run_request "$string_true" "$running"
expect_status 12 run_request "$invalid_json" "$running"
expect_status 12 run_request "$wrong_target" "$running"
expect_status 12 run_request "$wrong_operation" "$running"
for response in "$bad_request" "$forbidden" "$conflict" "$missing"; do
    expect_status 12 run_request "$response" "$running"
done
expect_status 10 run_request "$forbidden" "$cancelled"
expect_status 10 run_request "$forbidden" "$superseded"
expect_status 10 run_request "$missing" "$deleted_404"
expect_status 12 run_request "$missing" "$html_404"
expect_status 12 run_request "$forbidden" "$unauthorized"
expect_status 11 run_request "$server_error" "$running"
expect_status 11 run_request "$transport_failure" "$running"
expect_status 12 run_request "$forbidden" "$transport_failure"

# Missing identity context or API configuration is retryable and must not emit
# a permit request.  The curl mock makes any accidental request observable.
for missing_mode in context api; do
    set +e
    (
        taskid=7 task_token='test-token-0123456789' mac='00:0c:29:ae:cc:4f'
        pxeapi='' web=''
        curl_marker="$tmp/missing-$missing_mode.curl"
        curl() { : >"$curl_marker"; return 70; }
        if [[ $missing_mode == context ]]; then
            rootpxe_require_task_context() { return 1; }
        else
            rootpxe_require_task_context() { return 0; }
        fi
        . "$tmp/permit.sh"
        rootpxe_request_disk_permit_for_target 'disk-serial-1' deploy_write
        result=$?
        [[ $result -eq 11 && ! -e $curl_marker ]]
    ) >"$tmp/missing-$missing_mode.out" 2>&1
    missing_status=$?
    set -e
    [[ $missing_status -eq 0 ]] || fail "missing $missing_mode did not safely retry without curl"
done

# Successful grants must overwrite old flags; a later denial must clear them.
set +e
(
    rootpxe_disk_permit_granted=yes
    rootpxe_disk_permit_target_id=stale-target
    rootpxe_disk_permit_operation=stale-operation
    run_request "$bad_request" "$running"
    result=$?
    [[ $result -eq 12 ]] || exit 91
    [[ -z ${rootpxe_disk_permit_granted:-} && -z ${rootpxe_disk_permit_target_id:-} && -z ${rootpxe_disk_permit_operation:-} ]]
) >"$tmp/stale.out" 2>&1
stale_status=$?
set -e
[[ $stale_status -eq 0 ]] || fail 'a rejected permit retained stale grant flags'

# An explicit denial must report through the existing error-wait path.  Its
# known terminal result maps to 20; any abnormal callback result is retried.
set +e
(
    taskid=7 task_token='test-token-0123456789' mac='00:0c:29:ae:cc:4f'
    pxeapi='https://rootpxe.invalid/api/'
    curl() {
        case " $* " in
            *disk-permit*) printf '%s' "$forbidden" ;;
            *task-status*) printf '%s' "$running" ;;
            *) return 1 ;;
        esac
    }
    rootpxe_require_task_context() { return 0; }
    rootpxe_error_wait_for_retry() { printf 'report:%s:%s\n' "$1" "$2"; return 2; }
    sleep() { printf 'sleep:%s\n' "$1"; }
    . "$tmp/permit.sh"
    if rootpxe_wait_for_disk_permit 'disk-serial-1' deploy_write; then
        exit 90
    else
        result=$?
    fi
    [[ $result -eq 20 ]]
) >"$tmp/attention.out" 2>&1
attention_status=$?
set -e
[[ $attention_status -eq 0 ]] || fail 'permit denial did not reach error wait terminal path'
grep -Fqx 'report:任务或磁盘绑定校验被拒绝，请确认任务状态。（HTTP 403，DISK_PERMIT_TASK_REJECTED）:PXEOS_DISK_PERMIT_DENIED' "$tmp/attention.out" || fail 'permit denial report contract changed'
grep -Fq '[ERROR] Disk permission denied (HTTP 403).' "$tmp/attention.out" || fail 'HTTP diagnosis missing'
grep -Fqx '[INFO]  Server code: DISK_PERMIT_TASK_REJECTED.' "$tmp/attention.out" || fail 'known permit code diagnosis missing'
! grep -Fq 'test-token-0123456789' "$tmp/attention.out" || fail 'task token leaked to console'
! grep -Fq '"error":"forbidden"' "$tmp/attention.out" || fail 'raw response body leaked to console'

set +e
(
    taskid=7 task_token='test-token-0123456789' mac='00:0c:29:ae:cc:4f'
    pxeapi='https://rootpxe.invalid/api/'
    curl() {
        case " $* " in
            *disk-permit*) printf '%s' "$unknown_code" ;;
            *task-status*) printf '%s' "$running" ;;
            *) return 1 ;;
        esac
    }
    rootpxe_require_task_context() { return 0; }
    rootpxe_error_wait_for_retry() { return 2; }
    sleep() { :; }
    . "$tmp/permit.sh"
    if rootpxe_wait_for_disk_permit 'disk-serial-1' deploy_write; then
        exit 90
    else
        result=$?
    fi
    [[ $result -eq 20 ]]
) >"$tmp/unknown-code.out" 2>&1
unknown_status=$?
set -e
[[ $unknown_status -eq 0 ]] || fail 'unknown permit code did not enter attention path'
! grep -Fq 'DISK_PERMIT_UNRECOGNIZED' "$tmp/unknown-code.out" || fail 'unknown permit code leaked to console'
! grep -Fq 'do-not-show' "$tmp/unknown-code.out" || fail 'unknown permit response leaked to console'

# A non-terminal report callback must not become cancellation/reboot.  The
# second mocked request grants permission, proving the loop safely continues.
set +e
(
    taskid=7 task_token='test-token-0123456789' mac='00:0c:29:ae:cc:4f'
    pxeapi='https://rootpxe.invalid/api/'
    counter="$tmp/retry-count"
    : >"$counter"
    curl() {
        case " $* " in
            *disk-permit*)
                count=$(wc -l <"$counter")
                printf 'x\n' >>"$counter"
                if [[ $count -eq 0 ]]; then printf '%s' "$forbidden"; else printf '%s' "$success"; fi
                ;;
            *task-status*) printf '%s' "$running" ;;
            *) return 1 ;;
        esac
    }
    rootpxe_require_task_context() { return 0; }
    rootpxe_error_wait_for_retry() { return 1; }
    sleep() { printf 'sleep:%s\n' "$1"; }
    . "$tmp/permit.sh"
    rootpxe_wait_for_disk_permit 'disk-serial-1' deploy_write
) >"$tmp/retry.out" 2>&1
retry_status=$?
set -e
[[ $retry_status -eq 0 ]] || fail 'abnormal error-wait callback did not safely retry'
grep -Fqx 'sleep:5' "$tmp/retry.out" || fail 'abnormal error-wait callback must sleep before retry'

# All three top-level call sites may only make cancellation (10) or completed
# attention (20) terminal.  A catch-all reboot branch would reintroduce the
# immediate-reboot failure this contract prevents.
upload="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.upload"
download="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.download"
for script in "$upload" "$download"; do
    grep -Fq 'if rootpxe_wait_for_disk_permit ' "$script" || fail "$script does not collect permit failures with if/else"
done
[[ $(grep -Fc 'if rootpxe_wait_for_disk_permit ' "$download") -eq 2 ]] || fail 'download must protect both normal and resume permit paths'
[[ $(grep -hFc '20) exit 2' "$upload" "$download" | awk '{ total += $1 } END { print total }') -eq 3 ]] || fail 'all permit callers must preserve error-wait terminal action'
! grep -Fq '*) printf '\''%s\n'\'' reboot' "$upload" "$download" || fail 'permit callers retain an immediate-reboot catch-all'

# Run only the three permit gates extracted from the top-level scripts.  A
# completed attention wait (20) must stop before postinit, image work, or the
# resume postdeploy hook.  The snippets never receive a grant and therefore do
# not write /tmp state, mount storage, or touch a disk.
awk '/^capture_target_id=/ { armed = 1 } armed && /^while :; do/ { copy = 1 } copy { print } copy && /^done$/ { getline; print; exit }' "$upload" >"$tmp/upload-gate.sh"
awk '/^rootpxe_plan_deploy_disk_operation/ { armed = 1 } armed && /^while :; do/ { copy = 1 } copy { print } copy && /^done$/ { getline; print; exit }' "$download" >"$tmp/download-gate.sh"
awk '/^if \[\[ \$\{resumeStage:-\} == customizing_hostname \]\]/ { copy = 1 } /^if \[\[ \$\{imgType:-\}/ { exit } copy' "$download" >"$tmp/resume-gate.sh"
for snippet in "$tmp/upload-gate.sh" "$tmp/download-gate.sh" "$tmp/resume-gate.sh"; do
    [[ -s $snippet ]] || fail "empty dynamic permit gate: $snippet"
    bash -n "$snippet" || fail "invalid dynamic permit gate: $snippet"
done

expect_terminal_gate() {
    local name="$1" snippet="$2" mode="$3" status
    set +e
    (
        set -e
        capture_target_id=disk-serial-1
        rootpxe_planned_target_id=disk-serial-1
        rootpxe_planned_disk_operation=deploy_write
        resumeStage="$mode"
        hd=/dev/mockdisk
        changeHostname=false
        rootpxe_disk_stable_identity() { printf 'disk-serial-1\n'; }
        permit_wait_calls=0
        rootpxe_wait_for_disk_permit() {
            permit_wait_calls=$((permit_wait_calls + 1))
            if [[ $permit_wait_calls -eq 1 ]]; then return 99; fi
            return 20
        }
        sleep() { printf 'sleep:%s\n' "$1"; }
        rootpxe_run_postinit() { printf 'UNEXPECTED:postinit\n'; return 0; }
        rootpxe_stage() { printf 'UNEXPECTED:stage\n'; return 0; }
        rootpxe_apply_hostname_for_disk() { printf 'UNEXPECTED:hostname\n'; return 0; }
        . "$snippet"
    ) >"$tmp/$name.out" 2>&1
    status=$?
    set -e
    [[ $status -eq 2 ]] || fail "$name did not stop after completed attention wait: $status"
    ! grep -Fq 'UNEXPECTED:' "$tmp/$name.out" || fail "$name ran a hook, image stage, or resume action after permit failure"
    grep -Fqx 'sleep:5' "$tmp/$name.out" || fail "$name did not safely retry an unknown permit result"
}

expect_terminal_gate upload "$tmp/upload-gate.sh" ''
expect_terminal_gate download "$tmp/download-gate.sh" ''
expect_terminal_gate resume "$tmp/resume-gate.sh" customizing_hostname

echo 'PASS: disk permit rejection waits for attention; only confirmed cancellation exits'
