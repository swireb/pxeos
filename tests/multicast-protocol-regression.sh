#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh"
JQ=/c/Windows/System32/jq.exe
[[ -x $JQ && -r $lib ]] || { echo 'FAIL: real jq or multicast library missing' >&2; exit 1; }
jq() { "$JQ" "$@"; }
sleep() { :; }
udp-receiver() { [[ ${1:-} == --help ]] && printf '%s\n' 'udp-receiver --nokbd --portbase --ttl --mcast-rdv-address --start-timeout --receive-timeout'; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
session=manual-session-aaaaaaaaaaaaaaaa
stream=cccccccccccccccccccccccccccccccc
curl() {
  local out='' url='' arg body=''
  while (( $# )); do
    case $1 in
      -o) out=$2; shift 2;;
      --data-binary) arg=$2; shift 2;;
      *) url=$1; shift;;
    esac
  done
  body=$(cat "${arg#@}")
  [[ $body != *secret-token* || $arg == @* ]] || return 91
  case $url in
    *join) printf '{"sessionId":"%s","state":"WAITING","deadlineAt":"x","readyCount":1,"candidateCount":1,"selectedCount":0,"member":{"state":"READY","selected":false}}' "$session" >"$out";;
    *prepare) printf '{"sessionId":"%s","streamId":"%s","sequence":1,"portBase":9000,"multicastAddress":"239.1.2.3","ttl":32,"senderAddress":"10.1.2.3","receiverTimeoutSec":300}' "$session" "$stream" >"$out";;
    *status) printf '{"sessionId":"%s","state":"RUNNING","deadlineAt":"x","currentSequence":2,"member":{"state":"RUNNING","selected":true}}' "$session" >"$out";;
    *end) printf '{"sessionId":"%s","completed":true}' "$session" >"$out";;
    *) printf '{"sessionId":"%s"}' "$session" >"$out";;
  esac
  printf 200
}
. "$lib"
taskType=deploy multicastTransportMode=multicast multicastSessionId="$session" multicastWaitTimeoutSec=1 taskid=9 task_token=secret-token mac=aa:bb:cc:dd:ee:ff progress_attempt=1 rootpxe_api=http://controller/
mkdir -p "$tmp/image"
printf x >"$tmp/image/d1p1.img.000"; printf y >"$tmp/image/d1p1.img.001"; printf z >"$tmp/image/d1p1.lvm.lv.root.img"; printf s >"$tmp/image/d1p1.swap.img"
cat >"$tmp/schema.json" <<'EOF'
{"partitions":[{"artifact":"d1p1.img"},{"artifact":"d1p1.swap.img","role":"swap"}],"lvm":{"vgs":[{"lvs":[{"artifact":"d1p1.lvm.lv.root.img"},{"artifact":""}]}]}}
EOF
imgType=n originalSchemaFile="$tmp/schema.json"
rootpxe_multicast_build_manifest "$tmp/image"
jq -e 'length==2 and .[0].artifactKey=="d1p1.img" and .[0].paths==["d1p1.img.000","d1p1.img.001"] and .[1].artifactKey=="d1p1.lvm.lv.root.img"' "$rootpxe_multicast_manifest_file" >/dev/null
rootpxe_multicast_join
rootpxe_multicast_wait_for_selection
rootpxe_multicast_prepare_stream d1p1.img
[[ $rootpxe_multicast_receiver_timeout_sec == 300 ]]
rootpxe_multicast_ready
rootpxe_multicast_report true
rootpxe_multicast_wait_sequence
rootpxe_multicast_end
[[ $rootpxe_multicast_data_complete == yes ]]
rootpxe_multicast_reset_attempt
printf x >"$tmp/image/duplicate.img"; printf y >"$tmp/image/duplicate.img.000"
rootpxe_multicast_artifact_paths "$tmp/image" duplicate.img && { echo 'FAIL: whole and split input accepted' >&2; exit 1; }
mkdir -p "$tmp/fixed"; printf x >"$tmp/fixed/d1p1.img"; printf y >"$tmp/fixed/d2p1.img"
cat >"$tmp/inventory.json" <<'EOF'
{"disks":[{"number":1,"partitions":[{"number":1,"typeGuid":"83","fs":"ext4"},{"number":2,"typeGuid":"82","fs":"swap"}]},{"number":2,"partitions":[{"number":1,"typeGuid":"83","fs":"ext4"}]}]}
EOF
imgType=mpa partitionInventoryFile="$tmp/inventory.json"
rootpxe_multicast_build_manifest "$tmp/fixed"
jq -e '[.[].artifactKey]==["d1p1.img","d2p1.img"]' "$rootpxe_multicast_manifest_file" >/dev/null
rootpxe_multicast_reset_attempt
printf raw >"$tmp/fixed/raw.img.000"; imgType=dd img=raw.img
rootpxe_multicast_build_manifest "$tmp/fixed"
jq -e '.[0].artifactKey=="raw.img" and .[0].paths==["raw.img.000"]' "$rootpxe_multicast_manifest_file" >/dev/null

# A healthy READY member only renews status.  A recoverable status network
# failure is retried within the original deadline; once the server reports
# PENDING, it is an explicit invitation to join again.
multicastWaitTimeoutSec=60
sleep() { SECONDS=$((SECONDS + 1)); }
status_calls=0
join_calls=0
rootpxe_multicast_status() {
  status_calls=$((status_calls+1))
  case $status_calls in
    1) rootpxe_multicast_state=WAITING; rootpxe_multicast_member_state=READY; rootpxe_multicast_member_selected=false ;;
    2) rootpxe_multicast_last_failure=network; return 1 ;;
    3) rootpxe_multicast_state=WAITING; rootpxe_multicast_member_state=PENDING; rootpxe_multicast_member_selected=false ;;
    *) rootpxe_multicast_state=RUNNING; rootpxe_multicast_member_state=RUNNING; rootpxe_multicast_member_selected=true ;;
  esac
}
rootpxe_multicast_join() { join_calls=$((join_calls+1)); rootpxe_multicast_state=WAITING; rootpxe_multicast_member_state=READY; rootpxe_multicast_member_selected=false; }
rootpxe_multicast_wait_for_selection
[[ $join_calls == 1 ]]

# PENDING actively joins.  A join response that has already frozen the
# member as selected RUNNING is a successful selection, not a race failure.
status_calls=0
join_calls=0
rootpxe_multicast_status() {
  status_calls=$((status_calls+1))
  rootpxe_multicast_state=WAITING; rootpxe_multicast_member_state=PENDING; rootpxe_multicast_member_selected=false
}
rootpxe_multicast_join() { join_calls=$((join_calls+1)); rootpxe_multicast_state=RUNNING; rootpxe_multicast_member_state=RUNNING; rootpxe_multicast_member_selected=true; }
rootpxe_multicast_wait_for_selection
[[ $join_calls == 1 ]]

# Join transport failures return to status polling and retry PENDING within
# the deadline. Authentication/HTTP rejection stops instead of retrying.
status_calls=0
join_calls=0
rootpxe_multicast_status() {
  status_calls=$((status_calls+1))
  rootpxe_multicast_state=WAITING; rootpxe_multicast_member_state=PENDING; rootpxe_multicast_member_selected=false
}
rootpxe_multicast_join() {
  join_calls=$((join_calls+1))
  if [[ $join_calls == 1 ]]; then rootpxe_multicast_last_failure=network; return 1; fi
  rootpxe_multicast_state=RUNNING; rootpxe_multicast_member_state=RUNNING; rootpxe_multicast_member_selected=true
}
rootpxe_multicast_wait_for_selection
[[ $join_calls == 2 ]]

status_calls=0
join_calls=0
rootpxe_multicast_status() { rootpxe_multicast_state=WAITING; rootpxe_multicast_member_state=PENDING; rootpxe_multicast_member_selected=false; }
rootpxe_multicast_join() { join_calls=$((join_calls+1)); rootpxe_multicast_last_failure=rejected; return 1; }
if rootpxe_multicast_wait_for_selection; then echo 'FAIL: rejected join was retried' >&2; exit 1; fi
[[ $join_calls == 1 ]]

# A zero remaining budget needs exactly one status-only final check: the
# controller may have swept WAITING to RUNNING in the preceding second.
status_calls=0
rootpxe_multicast_status() {
  status_calls=$((status_calls+1))
  if [[ $status_calls == 1 ]]; then
    rootpxe_multicast_state=WAITING; rootpxe_multicast_member_state=READY; rootpxe_multicast_member_selected=false; rootpxe_multicast_remaining_wait_sec=0
  else
    rootpxe_multicast_state=RUNNING; rootpxe_multicast_member_state=RUNNING; rootpxe_multicast_member_selected=true
  fi
}
rootpxe_multicast_wait_for_selection
[[ $status_calls == 2 ]]

# Per-stream progress must use prepare.receiverTimeoutSec, never the session
# creation budget (which is intentionally shorter here).
rootpxe_multicast_receiver_timeout_sec=2
multicastWaitTimeoutSec=1
[[ $(rootpxe_multicast_stream_wait_timeout) == 2 ]]
multicastWaitTimeoutSec=60
unset rootpxe_multicast_remaining_wait_sec
# A terminal server state is authoritative and never results in a join retry.
status_calls=0
join_calls=0
rootpxe_multicast_status() {
  status_calls=$((status_calls+1))
  rootpxe_multicast_state=FAILED; rootpxe_multicast_member_state=FAILED; rootpxe_multicast_member_selected=false
}
if rootpxe_multicast_wait_for_selection; then echo 'FAIL: terminal state was accepted' >&2; exit 1; fi
[[ $join_calls == 0 ]]

cancel_calls=0
rootpxe_multicast_cancel() { cancel_calls=$((cancel_calls+1)); }
rootpxe_multicast_data_complete=no
rootpxe_multicast_state=COMPLETED
rootpxe_multicast_member_state=RUNNING
rootpxe_multicast_cleanup
[[ $cancel_calls == 0 ]]
rootpxe_multicast_state=RUNNING
rootpxe_multicast_member_state=RUNNING
rootpxe_multicast_local_failure=yes
rootpxe_multicast_cleanup
[[ $cancel_calls == 0 ]]
echo 'PASS: multicast real-jq protocol regression'
