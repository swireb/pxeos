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
group=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
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
    *join) printf '{"groupId":"%s","joinWindowSec":1,"readyTimeoutSec":1}' "$group" >"$out";;
    *prepare) printf '{"groupId":"%s","streamId":"%s","sequence":1,"portBase":9000,"multicastAddress":"239.1.2.3","ttl":32,"senderAddress":"10.1.2.3"}' "$group" "$stream" >"$out";;
    *status) printf '{"state":"streaming","currentSequence":2,"completed":true}' >"$out";;
    *end) printf '{"completed":true}' >"$out";;
    *) printf '{}' >"$out";;
  esac
  printf 200
}
. "$lib"
taskType=deploy multicastTransportMode=multicast taskid=9 task_token=secret-token mac=aa:bb:cc:dd:ee:ff progress_attempt=1 rootpxe_api=http://controller/
mkdir -p "$tmp/image"
printf x >"$tmp/image/d1p1.img.000"; printf y >"$tmp/image/d1p1.img.001"; printf z >"$tmp/image/d1p1.lvm.lv.root.img"
cat >"$tmp/schema.json" <<'EOF'
{"partitions":[{"artifact":"d1p1.img"}],"lvm":{"vgs":[{"lvs":[{"artifact":"d1p1.lvm.lv.root.img"},{"artifact":""}]}]}}
EOF
imgType=n originalSchemaFile="$tmp/schema.json"
rootpxe_multicast_build_manifest "$tmp/image"
jq -e 'length==2 and .[0].artifactKey=="d1p1.img" and .[0].paths==["d1p1.img.000","d1p1.img.001"] and .[1].artifactKey=="d1p1.lvm.lv.root.img"' "$rootpxe_multicast_manifest_file" >/dev/null
rootpxe_multicast_join
rootpxe_multicast_prepare_stream d1p1.img
rootpxe_multicast_ready
rootpxe_multicast_report true
rootpxe_multicast_wait_sequence
rootpxe_multicast_end
[[ $rootpxe_multicast_completed == yes ]]
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
echo 'PASS: multicast real-jq protocol regression'
