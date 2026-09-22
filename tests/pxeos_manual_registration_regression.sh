#!/usr/bin/env bash
# Manual-registration client regression.  All endpoint, console and reboot
# interactions below are command mocks; it never touches a device or network.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
client="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/bin/pxeos.man.reg"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
init="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/etc/init.d/S99pxeos"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
must_not_have() { if grep -Fq -- "$2" "$1"; then fail "forbidden: $2"; fi; }

must_have "$client" 'PXEOS_MANREG_TTY'
must_have "$client" 'sha256//'
must_have "$client" '--max-redirs 0'
must_have "$client" "--proto '=https'"
must_have "$client" 'DIALOG_ESC=10 DIALOG_ERROR=255'
must_have "$client" 'formfield TAB form_NEXT'
must_have "$client" 'formfield BTAB form_prev'
must_have "$client" "item=(0 'No group')"
must_have "$client" 'Previous page'
must_have "$client" 'Next page'
must_have "$client" 'Network interrupted. Retrying commit.'
must_have "$client" 'Commit response is incomplete. Retrying commit.'
must_have "$client" 'Cancellation failed. Retry cancellation?'
must_have "$client" 'SESSION_EXPIRED|AUTH_REVOKED'
must_have "$client" 'choose_image; rc=$?'
must_have "$client" 'import_manual_kernel_args'
must_have "$client" 'wipe_secret "$tmpdir/login.json"'
must_have "$client" "'{bootToken:\$bootToken}'"
must_have "$client" 'expect_confirm'
must_have "$client" 'expect_commit'
must_not_have "$client" 'jq -n --arg'
must_not_have "$client" 'if [[ $task == none ]]'
must_have "$funcs" 'manual_spki_pin'
must_have "$funcs" 'manual_platform'
must_have "$init" 'if [[ $mode == manreg ]]; then'
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
    commit.1) body='{"completed":true,"hostId":9,"taskId":0,"taskType":"none","message":"done"}' ;;
    *) body='{"code":"SERVICE_UNAVAILABLE","message":"unavailable"}' ;;
  esac
else case "$action.$count" in
  login.1) body='{"ticket":"ticket-1","expiresInSeconds":600}' ;;
  options.1) body='{"taskType":"deploy","images":[{"id":1,"name":"First\u001bName"}],"groups":[],"page":1,"hasNext":true}' ;;
  options.2) body='{"taskType":"deploy","images":[{"id":42,"name":"Second"}],"groups":[],"page":2,"hasNext":false}' ;;
  options.3) body='{"taskType":"deploy","images":[],"groups":[{"id":7,"name":"Ops"}],"page":1,"hasNext":false}' ;;
  confirm.1) body='{"confirmed":true,"hostName":"node-01","imageId":42,"imageName":"Second","groupId":0,"groupName":"No group","taskType":"deploy","dangerous":true}' ;;
  commit.1) exit 7 ;;
  commit.2) body='{"completed":true,"hostId":9,"taskId":10,"taskType":"deploy","message":"done"}' ;;
  *) body='{"code":"SERVICE_UNAVAILABLE","message":"unavailable"}' ;;
esac
fi
printf '%s' "$body" >"$out"
printf '200'
EOF
cat >"$tmp/bin/reboot" <<'EOF'
#!/usr/bin/env bash
printf 'reboot\n' >>"$PXEOS_TEST_REBOOT_LOG"
EOF
chmod +x "$tmp/bin/dialog" "$tmp/bin/curl" "$tmp/bin/reboot"

PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" \
PXEOS_MANREG_TTY="$tmp/tty" \
PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" \
PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" \
PXEOS_TEST_STATE="$tmp/state" \
PXEOS_TEST_REQUESTS="$tmp/requests" \
PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" \
PXEOS_TEST_RUNTIME_DIR="$tmp/runtime-dir" \
pxeapi='https://192.0.2.1:9443/service/pxeos/' manual_token='boot-token' \
manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" \
bash "$client"

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
[[ $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'successful commit did not cause exactly one reboot'
! grep -Fq 'pa ss$[]' "$tmp/curl-args.log" || fail 'password leaked to curl argv'
runtime_dir=$(<"$tmp/runtime-dir")
[[ ! -d $runtime_dir ]] || fail 'manual-registration credentials directory was not cleaned'

# Registration-only remains a complete image/group/confirm flow and accepts
# the contract's taskId=0 terminal result exactly once.
rm -rf "$tmp/state" "$tmp/requests"; mkdir "$tmp/state" "$tmp/requests"; rm -f "$tmp/reboot.log"
PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" PXEOS_TEST_TASK=none PXEOS_MANREG_TTY="$tmp/tty" PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" PXEOS_TEST_STATE="$tmp/state" PXEOS_TEST_REQUESTS="$tmp/requests" PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" PXEOS_TEST_RUNTIME_DIR="$tmp/runtime-dir" pxeapi='https://192.0.2.1:9443/service/pxeos/' manual_token='boot-token' manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" bash "$client"
[[ $(jq -r '.taskType' "$tmp/requests/confirm.1.json") == none ]] || fail 'none did not reach confirmation'
[[ $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'none taskId 0 did not reboot exactly once'

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
PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" PXEOS_MANREG_TTY="$tmp/tty" PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" PXEOS_TEST_STATE="$tmp/state" PXEOS_TEST_REQUESTS="$tmp/requests" PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" pxeapi='https://192.0.2.1:9443/service/pxeos/' manual_token='boot-token' manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" bash "$client"
[[ $(<"$tmp/state/cancel") == 2 ]] || fail 'cancel failure was not retried'
[[ $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'successful cancellation did not reboot once'

# Additional bounded scripted cases use the same fixed PATH command mocks.  A
# shared scenario name makes every response and dialog decision explicit.
cat >"$tmp/bin/dialog" <<'EOF'
#!/usr/bin/env bash
set -u
args="$*"; state=$PXEOS_TEST_STATE
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
  *'Select task'*) printf 'none' >&2 ;;
  *'Select image'*) printf '42' >&2 ;;
  *'Select group'*) printf '0' >&2 ;;
  *'Confirm registration?'*)
    count=0; [[ -f $state/confirm-dialog ]] && count=$(<"$state/confirm-dialog"); count=$((count+1)); printf '%s' "$count" >"$state/confirm-dialog"
    [[ ${PXEOS_TEST_SCENARIO:-} == confirm-no && $count -eq 1 ]] && exit 1 ;;
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
  confirm-no.commit.1) body='{"completed":true,"hostId":9,"taskId":0,"taskType":"none","message":"done"}' ;;
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
  relogin-options.commit.1) body='{"completed":true,"hostId":9,"taskId":0,"taskType":"none","message":"done"}' ;;
  malformed-commit.login.1) body='{"ticket":"ticket-d","expiresInSeconds":600}' ;;
  malformed-commit.options.1) body='{"taskType":"none","images":[{"id":42,"name":"Ready"}],"groups":[],"page":1,"hasNext":false}' ;;
  malformed-commit.options.2) body='{"taskType":"none","images":[],"groups":[{"id":0,"name":"No group"}],"page":1,"hasNext":false}' ;;
  malformed-commit.confirm.1) body="{\"confirmed\":true,\"hostName\":\"$host\",\"imageId\":42,\"imageName\":\"Ready\",\"groupId\":0,\"groupName\":\"No group\",\"taskType\":\"none\",\"dangerous\":false}" ;;
  malformed-commit.commit.1) body='{"completed":true,"message":"missing ids"}' ;;
  malformed-commit.cancel.1) exit 7 ;;
  *) body='{"code":"SERVICE_UNAVAILABLE","message":"unexpected mock call"}' ;;
esac
printf '%s' "$body" >"$out"; printf '200'
EOF
chmod +x "$tmp/bin/dialog" "$tmp/bin/curl"

count_of() { local value=0; [[ -f $tmp/state/$1 ]] && value=$(<"$tmp/state/$1"); printf '%s' "$value"; }
run_case() {
  local scenario=$1 expected_rc=$2 rc runtime
  rm -rf -- "$tmp/state" "$tmp/requests"; mkdir "$tmp/state" "$tmp/requests"; : >"$tmp/reboot.log"; : >"$tmp/dialog.log"; : >"$tmp/curl-args.log"; : >"$tmp/runtime-dir"
  set +e
  PATH="$tmp/bin:/usr/bin:/bin:/c/Windows/system32" PXEOS_TEST_SCENARIO="$scenario" PXEOS_MANREG_TTY="$tmp/tty" PXEOS_TEST_DIALOG_LOG="$tmp/dialog.log" PXEOS_TEST_CURL_ARGS="$tmp/curl-args.log" PXEOS_TEST_STATE="$tmp/state" PXEOS_TEST_REQUESTS="$tmp/requests" PXEOS_TEST_REBOOT_LOG="$tmp/reboot.log" PXEOS_TEST_RUNTIME_DIR="$tmp/runtime-dir" pxeapi='https://192.0.2.1:9443/service/pxeos/' manual_token='boot-token' manual_spki_pin="sha256//$(printf 'A%.0s' {1..43})=" bash "$client"
  rc=$?
  set -e
  [[ $rc -eq $expected_rc ]] || fail "$scenario exited $rc, want $expected_rc"
  [[ $(count_of steps) -le 30 ]] || fail "$scenario exceeded 30 mock steps"
  runtime=$(<"$tmp/runtime-dir"); [[ ! -d $runtime ]] || fail "$scenario did not clean its own credential directory"
}

run_case confirm-no 0
[[ $(count_of login) -eq 1 && $(count_of confirm) -eq 2 && $(count_of commit) -eq 1 ]] || fail 'No confirmation did not return to edit flow'
[[ $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'confirmed retry did not reboot once'

run_case commit-no-cancel 0
[[ $(count_of login) -eq 1 && $(count_of commit) -eq 1 && $(count_of cancel) -eq 1 ]] || fail 'commit No path retried or skipped cancellation'
[[ $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 'successful cancellation did not reboot once'

run_case relogin-options 0
[[ $(count_of login) -eq 2 && $(count_of commit) -eq 1 ]] || fail 'SESSION_EXPIRED did not re-login before completion'
[[ $(wc -l <"$tmp/reboot.log") -eq 1 ]] || fail 're-login completion did not reboot once'

run_case malformed-commit 1
[[ $(count_of commit) -eq 1 && $(count_of cancel) -eq 1 ]] || fail 'malformed completion retried commit or cancellation unexpectedly'
[[ ! -s $tmp/reboot.log ]] || fail 'malformed completion rebooted unexpectedly'

# The manual branch is before RAID discovery and does not enter task rebooting.
man_line=$(grep -n 'if \[\[ \$mode == manreg \]\]; then' "$init" | cut -d: -f1)
raid_line=$(grep -n 'if \[\[ \$mdraid == true \]\]; then' "$init" | cut -d: -f1)
(( man_line < raid_line )) || fail 'manual registration runs after RAID discovery'
sed -n "${man_line},$((raid_line-1))p" "$init" | grep -Fq 'reboot -f' && fail 'manual branch inherited automatic reboot'

echo 'PASS: manual registration client contract is present'
