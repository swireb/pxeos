#!/usr/bin/env bash
# Manual-registration client regression.  All endpoint, console and reboot
# interactions below are command mocks; it never touches a device or network.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
client="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.man.reg"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
init="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/etc/init.d/S99pxeos"
checkin="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.checkin"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
must_not_have() { if grep -Fq -- "$2" "$1"; then fail "forbidden: $2"; fi; }

must_have "$client" 'PXEOS_MANREG_TTY'
must_have "$client" 'sha256//'
must_have "$client" '--max-redirs 0'
must_have "$client" "--proto '=https'"
must_have "$client" 'DIALOG_ESC=10 DIALOG_ERROR=255'
must_have "$client" '--insecure --mixedform'
must_have "$client" 'formfield TAB form_NEXT'
must_have "$client" 'formfield BTAB form_prev'
must_have "$client" "item=(0 'No group')"
must_have "$client" 'Previous page'
must_have "$client" 'Next page'
must_have "$client" 'Network interrupted. Retrying commit.'
must_have "$client" 'Commit response is incomplete. Retrying commit.'
must_have "$client" 'Cancellation failed. Retry cancellation?'
must_have "$client" 'SESSION_EXPIRED|AUTH_REVOKED'
must_have "$client" 'Registration is no longer pending.'
must_have "$client" 'This device is already registered.'
must_have "$client" 'Selected image is not ready.'
must_have "$client" 'Selected deployment layout is invalid.'
must_have "$client" 'Host name is invalid.'
must_have "$client" 'Reboot and follow the normal boot path.'
must_have "$client" 'return 13'
must_have "$client" 'choose_image; rc=$?'
must_have "$client" 'import_manual_kernel_args'
must_have "$client" 'wipe_secret "$tmpdir/login.json"'
must_have "$client" "'{bootToken:\$bootToken}'"
must_have "$client" 'expect_confirm'
must_have "$client" 'expect_commit'
must_have "$client" 'write_task_handoff'
must_have "$client" 'manual_mac=$(manual_normalize_mac'
must_have "$client" 'Task handoff is invalid. No disk operation was started.'
must_have "$client" 'return 20'
must_have "$client" "deploy 'Deploy image'"
must_have "$client" "reboot 'Reboot'"
must_have "$client" "poweroff 'Shut down'"
must_have "$client" 'Restart failed. Select an action.'
must_have "$client" 'Shut down failed. Select an action.'
must_not_have "$client" "deploy 'Deploy image (overwrites disk)'"
must_not_have "$client" 'jq -n --arg'
must_have "$funcs" 'manual_spki_pin'
must_have "$funcs" 'manual_platform'
must_have "$init" 'pxeos_manual_task_handoff()'
must_have "$init" 'manual_direct_task=yes'
must_have "$init" 'manual_spki_pin=${fields[5]}'
must_have "$init" 'if [[ $mode == manreg ]]; then'
must_have "$checkin" 'pxeos_checkin_runtime_setup()'
must_have "$checkin" '--max-redirs 0 --pinnedpubkey "$manual_spki_pin"'
must_have "$checkin" 'rootpxe_write_checkin_json_payload'
must_have "$checkin" '--rawfile token "$token_file"'
must_have "$checkin" '--data-binary "@$checkin_payload_file"'
must_not_have "$checkin" '--arg token "$task_token"'
must_not_have "$checkin" '--data-binary "$checkin_payload"'
must_have "$checkin" '[[ ${rootpxe_api:-} == https://* ]]'
must_have "$checkin" "--proto '=https' --proto-redir '=https' --max-redirs 0 --pinnedpubkey"
# A direct handoff has no legacy runtime arguments.  The identity helper must
# therefore initialize macWinSafe before the authenticated reply MAC check;
# runtime setup deliberately remains after checkin so it consumes only the
# authenticated task response.
identity_line=$(grep -n -m1 'rootpxe_require_identity ||' "$checkin" | cut -d: -f1)
reply_mac_line=$(grep -n -m1 'rootpxe_normalize_mac "\$reply_mac"' "$checkin" | cut -d: -f1)
runtime_call_line=$(grep -n -m1 '^pxeos_checkin_runtime_setup$' "$checkin" | cut -d: -f1)
[[ $identity_line =~ ^[0-9]+$ && $reply_mac_line =~ ^[0-9]+$ && $runtime_call_line =~ ^[0-9]+$ ]] || fail 'checkin identity ordering markers are missing'
(( identity_line < reply_mac_line && reply_mac_line < runtime_call_line )) || fail 'checkin MAC identity/runtime ordering is unsafe'
for config in "$root/configs/fsx64.config" "$root/configs/fsx86.config" "$root/configs/fsarm64.config"; do
    must_have "$config" 'BR2_PACKAGE_LIBCURL_CURL=y'
    must_not_have "$config" 'BR2_PACKAGE_CURL=y'
done

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/requests" "$tmp/state"
touch "$tmp/tty"

cat >"$tmp/bin/dialog" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$PXEOS_TEST_DIALOG_LOG"
args="$*"
if [[ -s ${PXEOS_TEST_RUNTIME_DIR:-/nonexistent} && $args != *--mixedform* ]]; then
  runtime_dir=$(<"$PXEOS_TEST_RUNTIME_DIR")
  [[ ! -e $runtime_dir/login.json && ! -e $runtime_dir/pass ]] && ! grep -Fq 'pa ss$[]' "$runtime_dir/dialog.out" 2>/dev/null || { printf 'secret file survived until next dialog\n' >&2; exit 255; }
fi
case $args in
  *--mixedform*) printf 'operator\npa ss$[]' >&2 ;;
  *'Host name'*) printf 'node-01' >&2 ;;
  *'Select task'*) printf '%s' "${PXEOS_TEST_TASK:-deploy}" >&2 ;;
  *'Select image (page 1)'*) printf '__next' >&2 ;;
  *'Select image (page 2)'*) printf '42' >&2 ;;
  *'Select group'*) printf '0' >&2 ;;
  *'Registration completed. Select an action.'*)
    count=0; [[ -f $PXEOS_TEST_STATE/power-menu ]] && count=$(<"$PXEOS_TEST_STATE/power-menu"); count=$((count+1)); printf '%s' "$count" >"$PXEOS_TEST_STATE/power-menu"
    case ${PXEOS_TEST_POWER_SCENARIO:-${PXEOS_TEST_POWER_ACTION:-}} in
      reboot) printf 'reboot' >&2 ;;
      poweroff) printf 'poweroff' >&2 ;;
      cancel-reboot) [[ $count -eq 1 ]] && exit 10; printf 'reboot' >&2 ;;
      fail-reboot-poweroff) [[ $count -eq 1 ]] && printf 'reboot' >&2 || printf 'poweroff' >&2 ;;
      fail-poweroff-reboot) [[ $count -eq 1 ]] && printf 'poweroff' >&2 || printf 'reboot' >&2 ;;
      *) exit 255 ;;
    esac ;;
  *) : ;;
esac
exit 0
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
out='' request=''
printf '%s\n' "$@" >>"$PXEOS_TEST_CURL_ARGS"
for ((i=1; i <= $#; i++)); do
  arg=${!i}
  if [[ $arg == --output ]]; then j=$((i+1)); out=${!j}; fi
  if [[ $arg == @* ]]; then request=${arg#@}; fi
done
action=${!#}; action=${action##*/}
task=${PXEOS_TEST_TASK:-deploy}
count_file="$PXEOS_TEST_STATE/$action"
count=0; [[ -f $count_file ]] && count=$(<"$count_file"); count=$((count+1)); printf '%s' "$count" >"$count_file"
cp "$request" "$PXEOS_TEST_REQUESTS/$action.$count.json"
[[ $action == login ]] && dirname "$request" >"$PXEOS_TEST_RUNTIME_DIR"
if [[ $task == none ]]; then
  case "$action.$count" in
    login.1) body='{"ticket":"ticket-1","expiresInSeconds":600}' ;;
    options.1) body='{"taskType":"none","images":[{"id":42,"name":"Second"}],"groups":[],"page":1,"hasNext":false}' ;;
    options.2) body='{"taskType":"none","images":[{"id":42,"name":"Second"}],"groups":[],"page":2,"hasNext":false}' ;;
    options.3) body='{"taskType":"none","images":[],"groups":[],"page":1,"hasNext":false}' ;;
    confirm.1) body='{"confirmed":true,"hostName":"node-01","imageId":42,"imageName":"Second","groupId":0,"groupName":"No group","taskType":"none","dangerous":false}' ;;
    commit.1) body='{"completed":true,"hostId":9,"taskId":0,"taskType":"none","mac":"00:11:22:33:44:55","message":"done"}' ;;
    *) body='{"code":"SERVICE_UNAVAILABLE","message":"unavailable"}' ;;
  esac
else case "$action.$count" in
  login.1) body='{"ticket":"ticket-1","expiresInSeconds":600}' ;;
  options.1) body="{\"taskType\":\"$task\",\"images\":[{\"id\":1,\"name\":\"First\\u001bName\"}],\"groups\":[],\"page\":1,\"hasNext\":true}" ;;
  options.2) body="{\"taskType\":\"$task\",\"images\":[{\"id\":42,\"name\":\"Second\"}],\"groups\":[],\"page\":2,\"hasNext\":false}" ;;
  options.3) body="{\"taskType\":\"$task\",\"images\":[],\"groups\":[{\"id\":7,\"name\":\"Ops\"}],\"page\":1,\"hasNext\":false}" ;;
  confirm.1) body="{\"confirmed\":true,\"hostName\":\"node-01\",\"imageId\":42,\"imageName\":\"Second\",\"groupId\":0,\"groupName\":\"No group\",\"taskType\":\"$task\",\"dangerous\":true}" ;;
  commit.1) exit 7 ;;
  commit.2) body="{\"completed\":true,\"hostId\":9,\"taskId\":10,\"taskType\":\"$task\",\"mac\":\"00:11:22:33:44:55\",\"executionToken\":\"ABCDEFGHIJKLMNOP\",\"message\":\"done\"}" ;;
  *) body='{"code":"SERVICE_UNAVAILABLE","message":"unavailable"}' ;;
esac
fi
printf '%s' "$body" >"$out"
printf '200'
EOF
cat >"$tmp/bin/reboot" <<'EOF'
#!/usr/bin/env bash
printf 'reboot\n' >>"$PXEOS_TEST_REBOOT_LOG"
[[ ${PXEOS_TEST_POWER_SCENARIO:-} == fail-reboot-poweroff ]] && exit 1
exit 0
EOF
cat >"$tmp/bin/poweroff" <<'EOF'
#!/usr/bin/env bash
printf 'poweroff\n' >>"$PXEOS_TEST_POWEROFF_LOG"
[[ ${PXEOS_TEST_POWER_SCENARIO:-} == fail-poweroff-reboot ]] && exit 1
exit 0
EOF
chmod +x "$tmp/bin/dialog" "$tmp/bin/curl" "$tmp/bin/reboot" "$tmp/bin/poweroff"

set +e
PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" \
PXEOS_MANREG_TTY="$tmp/tty" \
PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" \
PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" \
PXEOS_TEST_STATE="$tmp/state" \
PXEOS_TEST_REQUESTS="$tmp/requests" \
PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" \
PXEOS_TEST_RUNTIME_DIR="$tmp/runtime-dir" \
PXEOS_MANREG_HANDOFF_DIR="$tmp/handoff" pxeapi='https://192.0.2.1:9443/service/pxeos/' mac='00:11:22:33:44:55' manual_token='boot-token' \
manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" \
bash "$client"
rc=$?
set -e
[[ $rc -eq 20 ]] || fail "deploy handoff exited $rc, want 20"

[[ $(jq -r '.password' "$tmp/requests/login.1.json") == 'pa ss$[]' ]] || fail 'password changed before JSON encoding'
[[ $(jq -r '.imageId' "$tmp/requests/options.1.json") == 0 ]] || fail 'first image request did not use imageId 0'
[[ $(jq -r '.groupId' "$tmp/requests/confirm.1.json") == 0 ]] || fail 'No group was not sent as groupId 0'
grep -Fq 'Select image (page 1)' "$tmp/dialog.log" || fail 'first image page was not displayed'
grep -Fq 'Select image (page 2)' "$tmp/dialog.log" || fail 'next image page was not displayed'
grep -Fq 'WARNING:' "$tmp/dialog.log" || fail 'dangerous confirmation summary was not displayed'
grep -Fq 'Host: node-01' "$tmp/dialog.log" || fail 'confirmation lost ASCII host name'
grep -Fq 'Image: Second' "$tmp/dialog.log" || fail 'confirmation lost ASCII image name'
grep -Fq 'Group: No group' "$tmp/dialog.log" || fail 'confirmation lost ASCII group name'
! grep -Fq $'First\033Name' "$tmp/dialog.log" || fail 'control character reached dialog'
[[ ! -s $tmp/reboot.log ]] || fail 'deploy handoff rebooted before task checkin'
mapfile -t handoff_fields <"$tmp/handoff/context"
[[ ${handoff_fields[0]} == 10 && ${handoff_fields[2]} == 00:11:22:33:44:55 && ${handoff_fields[3]} == deploy ]] || fail 'deploy handoff context is invalid'
[[ ${handoff_fields[1]} == ABCDEFGHIJKLMNOP ]] || fail 'deploy handoff lost its execution token'
! grep -Fq 'pa ss$[]' "$tmp/curl-args.log" || fail 'password leaked to curl argv'
runtime_dir=$(<"$tmp/runtime-dir")
[[ ! -d $runtime_dir ]] || fail 'manual-registration credentials directory was not cleaned'

# Deploy and capture keep their direct task handoff: neither may enter the
# registration-only power menu or issue a power action before S99 check-in.
rm -rf "$tmp/state" "$tmp/requests" "$tmp/handoff"; mkdir "$tmp/state" "$tmp/requests"
: >"$tmp/reboot.log"; : >"$tmp/poweroff.log"; : >"$tmp/dialog.log"
set +e
PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" PXEOS_TEST_TASK=capture PXEOS_MANREG_TTY="$tmp/tty" PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" PXEOS_TEST_STATE="$tmp/state" PXEOS_TEST_REQUESTS="$tmp/requests" PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" PXEOS_TEST_POWEROFF_LOG="$tmp/poweroff.log" PXEOS_TEST_RUNTIME_DIR="$tmp/runtime-dir" PXEOS_MANREG_HANDOFF_DIR="$tmp/handoff" pxeapi='https://192.0.2.1:9443/service/pxeos/' mac='00:11:22:33:44:55' manual_token='boot-token' manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" bash "$client"
rc=$?
set -e
[[ $rc -eq 20 ]] || fail "capture handoff exited $rc, want 20"
mapfile -t handoff_fields <"$tmp/handoff/context"
[[ ${handoff_fields[0]} == 10 && ${handoff_fields[3]} == capture ]] || fail 'capture handoff context is invalid'
[[ ! -s $tmp/reboot.log && ! -s $tmp/poweroff.log ]] || fail 'capture changed to a completed power action'
! grep -Fq 'Registration completed. Select an action.' "$tmp/dialog.log" || fail 'capture entered the registration-only power menu'

# Registration-only remains a complete image/group/confirm flow.  Its
# taskId=0 completion asks for an explicit power action; it neither starts a
# task nor attempts a local-disk boot.
run_none_completion_case() {
  local power_scenario=$1
  rm -rf "$tmp/state" "$tmp/requests" "$tmp/handoff"; mkdir "$tmp/state" "$tmp/requests"
  : >"$tmp/reboot.log"; : >"$tmp/poweroff.log"; : >"$tmp/dialog.log"
  PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" PXEOS_TEST_TASK=none PXEOS_TEST_POWER_SCENARIO="$power_scenario" PXEOS_MANREG_TTY="$tmp/tty" PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" PXEOS_TEST_STATE="$tmp/state" PXEOS_TEST_REQUESTS="$tmp/requests" PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" PXEOS_TEST_POWEROFF_LOG="$tmp/poweroff.log" PXEOS_TEST_RUNTIME_DIR="$tmp/runtime-dir" PXEOS_MANREG_HANDOFF_DIR="$tmp/handoff" pxeapi='https://192.0.2.1:9443/service/pxeos/' mac='00:11:22:33:44:55' manual_token='boot-token' manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" bash "$client"
  [[ $(jq -r '.taskType' "$tmp/requests/confirm.1.json") == none ]] || fail "$power_scenario did not reach confirmation"
  [[ $(<"$tmp/state/commit") == 1 ]] || fail "$power_scenario repeated the completed commit"
  [[ ! -e $tmp/state/cancel ]] || fail "$power_scenario submitted an unexpected cancellation"
  [[ ! -e $tmp/handoff/context ]] || fail "$power_scenario created a task handoff"
}

run_none_completion_case reboot
[[ $(wc -l <"$tmp/reboot.log") -eq 1 && ! -s $tmp/poweroff.log ]] || fail 'registration-only reboot action was not explicit'
[[ $(<"$tmp/state/power-menu") == 1 ]] || fail 'registration-only reboot did not show the power menu'

run_none_completion_case poweroff
[[ ! -s $tmp/reboot.log && $(wc -l <"$tmp/poweroff.log") -eq 1 ]] || fail 'registration-only shut down action was not explicit'

run_none_completion_case cancel-reboot
[[ $(<"$tmp/state/power-menu") == 2 && $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'Esc/Cancel did not return to the completed power menu'

run_none_completion_case fail-reboot-poweroff
[[ $(<"$tmp/state/power-menu") == 2 && $(wc -l <"$tmp/reboot.log") -eq 1 && $(wc -l <"$tmp/poweroff.log") -eq 1 ]] || fail 'failed reboot did not return to the power menu'
grep -Fq 'Restart failed. Select an action.' "$tmp/dialog.log" || fail 'failed reboot did not explain the retry'

run_none_completion_case fail-poweroff-reboot
[[ $(<"$tmp/state/power-menu") == 2 && $(wc -l <"$tmp/poweroff.log") -eq 1 && $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'failed shut down did not return to the power menu'
grep -Fq 'Shut down failed. Select an action.' "$tmp/dialog.log" || fail 'failed shut down did not explain the retry'

# Esc at login exercises cancellation retry: a failed cancel leaves dialog in
# control, then a successful retry is the only path that invokes reboot.
sed 's/exit 0$/if [[ $args == *--mixedform* ]]; then exit 10; fi\nexit 0/' "$tmp/bin/dialog" >"$tmp/bin/dialog.cancel"
mv "$tmp/bin/dialog.cancel" "$tmp/bin/dialog"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
out=''; request=''
for ((i=1; i <= $#; i++)); do arg=${!i}; [[ $arg == --output ]] && { j=$((i+1)); out=${!j}; }; [[ $arg == @* ]] && request=${arg#@}; done
action=${!#}; action=${action##*/}; count_file="$PXEOS_TEST_STATE/cancel"; count=0; [[ -f $count_file ]] && count=$(<"$count_file"); count=$((count+1)); printf '%s' "$count" >"$count_file"
[[ $count -eq 1 ]] && exit 7
printf '{"cancelled":true}' >"$out"; printf '200'
EOF
chmod +x "$tmp/bin/dialog" "$tmp/bin/curl"
rm -f "$tmp/reboot.log" "$tmp/state/cancel"
PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" PXEOS_MANREG_TTY="$tmp/tty" PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" PXEOS_TEST_STATE="$tmp/state" PXEOS_TEST_REQUESTS="$tmp/requests" PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" PXEOS_MANREG_HANDOFF_DIR="$tmp/handoff" pxeapi='https://192.0.2.1:9443/service/pxeos/' mac='00:11:22:33:44:55' manual_token='boot-token' manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" bash "$client"
[[ $(<"$tmp/state/cancel") == 2 ]] || fail 'cancel failure was not retried'
[[ $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'successful cancellation did not reboot once'

# A terminal registration-only result returned by cancel is not a
# cancellation. It has no execution token and must remain in PXEOS without
# a local-boot marker/reboot.
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
out=''
for ((i=1; i <= $#; i++)); do arg=${!i}; [[ $arg == --output ]] && { j=$((i+1)); out=${!j}; }; done
action=${!#}; action=${action##*/}
count_file="$PXEOS_TEST_STATE/$action"; count=0; [[ -f $count_file ]] && count=$(<"$count_file"); count=$((count+1)); printf '%s' "$count" >"$count_file"
if [[ $action == login ]]; then
  printf '{"ticket":"ticket-terminal","expiresInSeconds":600}' >"$out"
else
  printf '{"completed":true,"hostId":9,"taskId":0,"taskType":"none","message":"done"}' >"$out"
fi
printf '200'
EOF
chmod +x "$tmp/bin/curl"
rm -f "$tmp/reboot.log" "$tmp/poweroff.log" "$tmp/state/cancel" "$tmp/state/power-menu"
PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" PXEOS_TEST_POWER_ACTION=poweroff PXEOS_MANREG_TTY="$tmp/tty" PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" PXEOS_TEST_STATE="$tmp/state" PXEOS_TEST_REQUESTS="$tmp/requests" PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" PXEOS_TEST_POWEROFF_LOG="$tmp/poweroff.log" PXEOS_MANREG_HANDOFF_DIR="$tmp/handoff" pxeapi='https://192.0.2.1:9443/service/pxeos/' mac='00:11:22:33:44:55' manual_token='boot-token' manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" bash "$client"
[[ ! -s $tmp/reboot.log && $(wc -l <"$tmp/poweroff.log") -eq 1 ]] || fail 'completed registration-only cancellation did not require an explicit power action'
[[ $(<"$tmp/state/cancel") == 1 && $(<"$tmp/state/power-menu") == 1 ]] || fail 'completed cancellation was retried instead of opening the power menu'
grep -Fq 'Registration completed. Select an action.' "$tmp/dialog.log" || fail 'completed registration-only cancellation did not show the power menu'

# Additional bounded scripted cases use the same fixed PATH command mocks.  A
# shared scenario name makes every response and dialog decision explicit.
cat >"$tmp/bin/dialog" <<'EOF'
#!/usr/bin/env bash
set -u
args="$*"; state=$PXEOS_TEST_STATE
printf '%s\n' "$args" >>"${PXEOS_TEST_DIALOG_LOG:-/dev/null}"
step=0; [[ -f $state/steps ]] && step=$(<"$state/steps"); step=$((step+1)); printf '%s' "$step" >"$state/steps"
(( step <= 30 )) || exit 255
if [[ -s ${PXEOS_TEST_RUNTIME_DIR:-/nonexistent} && $args != *--mixedform* ]]; then
  runtime_dir=$(<"$PXEOS_TEST_RUNTIME_DIR")
  [[ ! -e $runtime_dir/login.json && ! -e $runtime_dir/pass && ! -e $runtime_dir/user ]] || exit 255
  ! grep -Fq 'pa ss$[]' "$runtime_dir/dialog.out" 2>/dev/null || exit 255
fi
case $args in
  *--mixedform*) printf 'operator\npa ss$[]' >&2 ;;
  *'Host name'*)
    count=0; [[ -f $state/hostname ]] && count=$(<"$state/hostname"); count=$((count+1)); printf '%s' "$count" >"$state/hostname"
    [[ ${PXEOS_TEST_SCENARIO:-} == commit-no-cancel && $count -eq 2 ]] && exit 10
    printf 'node-%s' "${PXEOS_TEST_SCENARIO:-default}" >&2 ;;
  *'Select task'*)
    case ${PXEOS_TEST_SCENARIO:-} in direct-*) printf 'deploy' >&2 ;; *) printf 'none' >&2 ;; esac ;;
  *'Select image'*) printf '42' >&2 ;;
  *'Select group'*) printf '0' >&2 ;;
  *'Confirm registration?'*)
    count=0; [[ -f $state/confirm-dialog ]] && count=$(<"$state/confirm-dialog"); count=$((count+1)); printf '%s' "$count" >"$state/confirm-dialog"
    [[ ${PXEOS_TEST_SCENARIO:-} == confirm-no && $count -eq 1 ]] && exit 1 ;;
  *'Registration completed. Select an action.'*) printf 'poweroff' >&2 ;;
  *'Network interrupted.'*)
    [[ ${PXEOS_TEST_SCENARIO:-} == commit-no-cancel ]] && exit 1
    [[ ${PXEOS_TEST_SCENARIO:-} == malformed-commit ]] && exit 10 ;;
  *'Cancellation failed.'*) [[ ${PXEOS_TEST_SCENARIO:-} == malformed-commit ]] && exit 255 ;;
esac
exit 0
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
out='' request=''
for ((i=1; i <= $#; i++)); do
  arg=${!i}; [[ $arg == --output ]] && { j=$((i+1)); out=${!j}; }; [[ $arg == @* ]] && request=${arg#@}
done
state=$PXEOS_TEST_STATE; scenario=${PXEOS_TEST_SCENARIO:?}; action=${!#}; action=${action##*/}
step=0; [[ -f $state/steps ]] && step=$(<"$state/steps"); step=$((step+1)); printf '%s' "$step" >"$state/steps"; (( step <= 30 )) || exit 7
count=0; [[ -f $state/$action ]] && count=$(<"$state/$action"); count=$((count+1)); printf '%s' "$count" >"$state/$action"
cp "$request" "$PXEOS_TEST_REQUESTS/$action.$count.json"
[[ $action == login ]] && dirname "$request" >"$PXEOS_TEST_RUNTIME_DIR"
host="node-$scenario"
case "$scenario.$action.$count" in
  confirm-no.login.1) body='{"ticket":"ticket-a","expiresInSeconds":600}' ;;
  confirm-no.options.1) body='{"taskType":"none","images":[{"id":42,"name":"Ready"}],"groups":[],"page":1,"hasNext":false}' ;;
  confirm-no.options.2) body='{"taskType":"none","images":[],"groups":[{"id":0,"name":"No group"}],"page":1,"hasNext":false}' ;;
  confirm-no.options.3) body='{"taskType":"none","images":[{"id":42,"name":"Ready"}],"groups":[],"page":1,"hasNext":false}' ;;
  confirm-no.options.4) body='{"taskType":"none","images":[],"groups":[{"id":0,"name":"No group"}],"page":1,"hasNext":false}' ;;
  confirm-no.confirm.1|confirm-no.confirm.2) body="{\"confirmed\":true,\"hostName\":\"$host\",\"imageId\":42,\"imageName\":\"Ready\",\"groupId\":0,\"groupName\":\"No group\",\"taskType\":\"none\",\"dangerous\":false}" ;;
  confirm-no.commit.1) body='{"completed":true,"hostId":9,"taskId":0,"taskType":"none","mac":"00:11:22:33:44:55","message":"done"}' ;;
  commit-no-cancel.login.1) body='{"ticket":"ticket-b","expiresInSeconds":600}' ;;
  commit-no-cancel.options.1) body='{"taskType":"none","images":[{"id":42,"name":"Ready"}],"groups":[],"page":1,"hasNext":false}' ;;
  commit-no-cancel.options.2) body='{"taskType":"none","images":[],"groups":[{"id":0,"name":"No group"}],"page":1,"hasNext":false}' ;;
  commit-no-cancel.confirm.1) body="{\"confirmed\":true,\"hostName\":\"$host\",\"imageId\":42,\"imageName\":\"Ready\",\"groupId\":0,\"groupName\":\"No group\",\"taskType\":\"none\",\"dangerous\":false}" ;;
  commit-no-cancel.commit.1) exit 7 ;;
  commit-no-cancel.cancel.1) body='{"cancelled":true}' ;;
  relogin-options.login.1) body='{"ticket":"ticket-old","expiresInSeconds":600}' ;;
  relogin-options.login.2) body='{"ticket":"ticket-new","expiresInSeconds":600}' ;;
  relogin-options.options.1) printf '{"code":"SESSION_EXPIRED"}' >"$out"; printf '401'; exit 0 ;;
  relogin-options.options.2) body='{"taskType":"none","images":[{"id":42,"name":"Ready"}],"groups":[],"page":1,"hasNext":false}' ;;
  relogin-options.options.3) body='{"taskType":"none","images":[],"groups":[{"id":0,"name":"No group"}],"page":1,"hasNext":false}' ;;
  relogin-options.confirm.1) body="{\"confirmed\":true,\"hostName\":\"$host\",\"imageId\":42,\"imageName\":\"Ready\",\"groupId\":0,\"groupName\":\"No group\",\"taskType\":\"none\",\"dangerous\":false}" ;;
  relogin-options.commit.1) body='{"completed":true,"hostId":9,"taskId":0,"taskType":"none","mac":"00:11:22:33:44:55","message":"done"}' ;;
  malformed-commit.login.1) body='{"ticket":"ticket-d","expiresInSeconds":600}' ;;
  malformed-commit.options.1) body='{"taskType":"none","images":[{"id":42,"name":"Ready"}],"groups":[],"page":1,"hasNext":false}' ;;
  malformed-commit.options.2) body='{"taskType":"none","images":[],"groups":[{"id":0,"name":"No group"}],"page":1,"hasNext":false}' ;;
  malformed-commit.confirm.1) body="{\"confirmed\":true,\"hostName\":\"$host\",\"imageId\":42,\"imageName\":\"Ready\",\"groupId\":0,\"groupName\":\"No group\",\"taskType\":\"none\",\"dangerous\":false}" ;;
  malformed-commit.commit.1) body='{"completed":true,"message":"missing ids"}' ;;
  malformed-commit.cancel.1) exit 7 ;;
  commit-known-reason.login.1) body='{"ticket":"ticket-e","expiresInSeconds":600}' ;;
  commit-known-reason.options.1) body='{"taskType":"none","images":[{"id":42,"name":"Ready"}],"groups":[],"page":1,"hasNext":false}' ;;
  commit-known-reason.options.2) body='{"taskType":"none","images":[],"groups":[{"id":0,"name":"No group"}],"page":1,"hasNext":false}' ;;
  commit-known-reason.confirm.1) body="{\"confirmed\":true,\"hostName\":\"$host\",\"imageId\":42,\"imageName\":\"Ready\",\"groupId\":0,\"groupName\":\"No group\",\"taskType\":\"none\",\"dangerous\":false}" ;;
  commit-known-reason.commit.1) printf '{"code":"REGISTRATION_CONFLICT","message":"untrusted server text","reason":"MAC_ALREADY_REGISTERED"}' >"$out"; printf '409'; exit 0 ;;
  direct-missing-token.login.1|direct-bad-mac.login.1) body='{"ticket":"ticket-direct","expiresInSeconds":600}' ;;
  direct-missing-token.options.1|direct-bad-mac.options.1) body='{"taskType":"deploy","images":[{"id":42,"name":"Ready"}],"groups":[],"page":1,"hasNext":false}' ;;
  direct-missing-token.options.2|direct-bad-mac.options.2) body='{"taskType":"deploy","images":[],"groups":[{"id":0,"name":"No group"}],"page":1,"hasNext":false}' ;;
  direct-missing-token.confirm.1|direct-bad-mac.confirm.1) body="{\"confirmed\":true,\"hostName\":\"$host\",\"imageId\":42,\"imageName\":\"Ready\",\"groupId\":0,\"groupName\":\"No group\",\"taskType\":\"deploy\",\"dangerous\":true}" ;;
  direct-missing-token.commit.1) body='{"completed":true,"hostId":9,"taskId":10,"taskType":"deploy","mac":"00:11:22:33:44:55","message":"done"}' ;;
  direct-bad-mac.commit.1) body='{"completed":true,"hostId":9,"taskId":10,"taskType":"deploy","mac":"00:11:22:33:44:66","executionToken":"ABCDEFGHIJKLMNOP","message":"done"}' ;;
  *) body='{"code":"SERVICE_UNAVAILABLE","message":"unexpected mock call"}' ;;
esac
printf '%s' "$body" >"$out"; printf '200'
EOF
chmod +x "$tmp/bin/dialog" "$tmp/bin/curl"

count_of() { local value=0; [[ -f $tmp/state/$1 ]] && value=$(<"$tmp/state/$1"); printf '%s' "$value"; }
run_case() {
  local scenario=$1 expected_rc=$2 rc runtime
  rm -rf -- "$tmp/state" "$tmp/requests"; mkdir "$tmp/state" "$tmp/requests"; : >"$tmp/reboot.log"; : >"$tmp/poweroff.log"; : >"$tmp/dialog.log"; : >"$tmp/curl-args.log"; : >"$tmp/runtime-dir"
  set +e
  PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" PXEOS_TEST_SCENARIO="$scenario" PXEOS_MANREG_TTY="$tmp/tty" PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" PXEOS_TEST_STATE="$tmp/state" PXEOS_TEST_REQUESTS="$tmp/requests" PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" PXEOS_TEST_POWEROFF_LOG="$tmp/poweroff.log" PXEOS_TEST_RUNTIME_DIR="$tmp/runtime-dir" PXEOS_MANREG_HANDOFF_DIR="$tmp/handoff" pxeapi='https://192.0.2.1:9443/service/pxeos/' mac='00:11:22:33:44:55' manual_token='boot-token' manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" bash "$client"
  rc=$?
  set -e
  [[ $rc -eq $expected_rc ]] || fail "$scenario exited $rc, want $expected_rc"
  [[ $(count_of steps) -le 30 ]] || fail "$scenario exceeded 30 mock steps"
  runtime=$(<"$tmp/runtime-dir"); [[ ! -d $runtime ]] || fail "$scenario did not clean its own credential directory"
}

run_case confirm-no 0
[[ $(count_of login) -eq 1 && $(count_of confirm) -eq 2 && $(count_of commit) -eq 1 ]] || fail 'No confirmation did not return to edit flow'
[[ ! -s $tmp/reboot.log ]] || fail 'confirmed registration-only retry rebooted unexpectedly'

run_case commit-no-cancel 0
[[ $(count_of login) -eq 1 && $(count_of commit) -eq 1 && $(count_of cancel) -eq 1 ]] || fail 'commit No path retried or skipped cancellation'
[[ $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'successful cancellation did not reboot once'

run_case relogin-options 0
[[ $(count_of login) -eq 2 && $(count_of commit) -eq 1 ]] || fail 'SESSION_EXPIRED did not re-login before completion'
[[ ! -s $tmp/reboot.log ]] || fail 're-login registration-only completion rebooted unexpectedly'

run_case malformed-commit 1
[[ $(count_of commit) -eq 1 && $(count_of cancel) -eq 0 ]] || fail 'malformed completion retried commit or cancellation unexpectedly'
[[ ! -s $tmp/reboot.log ]] || fail 'malformed completion rebooted unexpectedly'
! grep -Fq 'Network interrupted.' "$tmp/dialog.log" || fail 'malformed completion was misclassified as a network retry'

run_case commit-known-reason 1
[[ $(count_of commit) -eq 1 ]] || fail 'known commit rejection retried a completed request'
[[ ! -s $tmp/reboot.log ]] || fail 'known commit rejection rebooted unexpectedly'
grep -Fq 'This device is already registered.' "$tmp/dialog.log" || fail 'known commit rejection did not show the trusted reason'
! grep -Fq 'untrusted server text' "$tmp/dialog.log" || fail 'server error text reached the console'

for scenario in direct-missing-token direct-bad-mac; do
  run_case "$scenario" 1
  [[ $(count_of commit) -eq 1 ]] || fail "$scenario retried a completed commit"
  [[ ! -s $tmp/reboot.log && ! -e $tmp/handoff/context ]] || fail "$scenario started a task or rebooted"
  ! grep -Fq 'Network interrupted.' "$tmp/dialog.log" || fail "$scenario was misclassified as a network retry"
  grep -Fq 'Task handoff is invalid. No disk operation was started.' "$tmp/dialog.log" || fail "$scenario did not show the local handoff failure"
done

# A deploy/capture handoff is consumed only by S99. It must restore the normal
# task preflight (including RAID) and never source the context as shell code.
mkdir "$tmp/mock-s99" "$tmp/s99-handoff"
sed "s|/tmp/pxeos-manual-task|$tmp/s99-handoff|g" "$init" >"$tmp/S99pxeos"
cat >"$tmp/mock-s99/pxeos.man.reg" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$PXEOS_S99_HANDOFF"
printf '%s\n%s\n%s\n%s\n%s\n%s\n' 10 ABCDEFGHIJKLMNOP 00:11:22:33:44:55 deploy true "sha256//$(printf 'A%.0s' {1..43})=" >"$PXEOS_S99_HANDOFF/context"
chmod 600 "$PXEOS_S99_HANDOFF/context"
exit 20
EOF
cat >"$tmp/mock-s99/pxeos" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s\n' "$type" "$taskid" "$task_token" "$manual_direct_task" "$mdraid" >>"$PXEOS_S99_LOG"
exit 0
EOF
cat >"$tmp/mock-s99/mdadm" <<'EOF'
#!/usr/bin/env bash
printf 'mdadm\n' >>"$PXEOS_S99_LOG"
EOF
cat >"$tmp/mock-s99/loadkeys" <<'EOF'
#!/usr/bin/env bash
printf 'loadkeys\n' >>"$PXEOS_S99_LOG"
EOF
cat >"$tmp/mock-s99/reboot" <<'EOF'
#!/usr/bin/env bash
printf 'reboot\n' >>"$PXEOS_S99_LOG"
EOF
cat >"$tmp/mock-s99/poweroff" <<'EOF'
#!/usr/bin/env bash
printf 'poweroff\n' >>"$PXEOS_S99_LOG"
EOF
cat >"$tmp/mock-s99/sleep" <<'EOF'
#!/usr/bin/env bash
:
EOF
chmod +x "$tmp/mock-s99"/* "$tmp/S99pxeos"
: >"$tmp/s99.log"
if ! PXEOS_S99_HANDOFF="$tmp/s99-handoff" PXEOS_S99_LOG="$tmp/s99.log" PATH="$tmp/mock-s99:$PATH" mode=manreg isdebug='' shutdown=0 bash "$tmp/S99pxeos" >"$tmp/s99.out" 2>&1; then
  cat "$tmp/s99.out" >&2
  fail 'manual task handoff init flow failed'
fi
grep -Fq 'mdadm' "$tmp/s99.log" || fail 'manual task handoff skipped RAID preflight'
grep -Fq 'down|10|ABCDEFGHIJKLMNOP|yes|true' "$tmp/s99.log" || fail 'manual task handoff did not restore the task context'
grep -Fq 'reboot' "$tmp/s99.log" || fail 'manual task handoff did not use normal completion action'
[[ ! -e $tmp/s99-handoff/context ]] || fail 'manual task handoff context was not removed by S99'

# The manual branch is before RAID discovery and does not enter task rebooting.
man_line=$(grep -n 'if \[\[ \$mode == manreg \]\]; then' "$init" | cut -d: -f1)
raid_line=$(grep -n 'if \[\[ \$mdraid == true \]\]; then' "$init" | cut -d: -f1)
(( man_line < raid_line )) || fail 'manual registration runs after RAID discovery'
sed -n "${man_line},$((raid_line-1))p" "$init" | grep -Fq 'reboot -f' && fail 'manual branch inherited automatic reboot'

echo 'PASS: manual registration client contract is present'
