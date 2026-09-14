#!/bin/bash
rootpxe_multicast_receiver_capable() {
 local h; command -v udp-receiver >/dev/null 2>&1 || return 1; h=$(udp-receiver --help 2>&1) || return 1
 [[ $h == *--nokbd* && $h == *--portbase* && $h == *--ttl* && $h == *--mcast-rdv-address* && $h == *--start-timeout* && $h == *--receive-timeout* ]]
}
rootpxe_multicast_runtime_ready() { command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && rootpxe_multicast_receiver_capable; }
rootpxe_multicast_reset() { unset multicastTransportMode multicastProtocolVersion multicastGroupId; mc=no; }
rootpxe_multicast_apply_transport_mode() {
 local d=$1 mode version; rootpxe_multicast_reset; mode=$(jq -r 'if has("transportMode") then .transportMode else "unicast" end' <<<"$d") || return 1
 [[ $mode == unicast || $mode == multicast ]] || return 1; [[ $mode != multicast || ${taskType:-} == deploy ]] || return 1
 if [[ $mode == multicast ]]; then version=$(jq -r .multicastProtocolVersion <<<"$d") || return 1; [[ $version == 1 ]] && rootpxe_multicast_runtime_ready || return 1; multicastTransportMode=multicast; multicastProtocolVersion=1; mc=yes
 else multicastTransportMode=unicast; multicastProtocolVersion=""; fi; export multicastTransportMode multicastProtocolVersion mc
}
rootpxe_multicast_safe_relative_path() {
 local p=$1 s; [[ -n $p && ${#p} -le 1024 && $p != /* && $p != */ && $p != *\\* && $p != *$'\n'* && $p != *$'\r'* && $p != *[[:cntrl:]]* && $p != *//* ]] || return 1
 IFS=/ read -r -a _mc_segments <<<"$p"; for s in "${_mc_segments[@]}"; do [[ -n $s && $s != . && $s != .. ]] || return 1; done; printf '%s\n' "$p"
}
rootpxe_multicast_artifact_key() { local p; p=$(rootpxe_multicast_safe_relative_path "$1") || return 1; printf '%s\n' "${p%.000}"; }
rootpxe_multicast_key_from_restore_source() {
 local source=$1 root=$2; source=${source%\*}; [[ $source == "$root/"* ]] || return 1
 rootpxe_multicast_artifact_key "${source#"$root/"}"
}
rootpxe_multicast_artifact_paths() {
 local root=$1 rel full parent s x suffix want=0 found=0; rel=$(rootpxe_multicast_artifact_key "$2") || return 1; [[ -d $root && ! -L $root ]] || return 1
 parent=$root; IFS=/ read -r -a _mc_segments <<<"$rel"; for s in "${_mc_segments[@]:0:${#_mc_segments[@]}-1}"; do parent=$parent/$s; [[ -d $parent && ! -L $parent ]] || return 1; done; full=$root/$rel
 if [[ -e $full || -L $full ]]; then [[ -f $full && ! -L $full && -r $full ]] || return 1; compgen -G "$full.*" >/dev/null && return 1; printf '%s\n' "$rel"; return 0; fi
 for x in "$full".*; do [[ -e $x || -L $x ]] || continue; suffix=${x##*.}; [[ $suffix =~ ^[0-9]{3}$ && -f $x && ! -L $x && -r $x && $suffix == $(printf '%03d' "$want") ]] || return 1; printf '%s\n' "${x#"$root/"}"; want=$((want+1)); found=1; done; [[ $found == 1 ]]
}
rootpxe_multicast_manifest_begin() { umask 077; rootpxe_multicast_manifest_file=$(mktemp /tmp/rootpxe-multicast-manifest.XXXXXX) || return 1; printf '[]\n' >"$rootpxe_multicast_manifest_file" && chmod 600 "$rootpxe_multicast_manifest_file"; }
rootpxe_multicast_manifest_add() {
 local m=$1 key=$2 root=$3 rel=$4 paths tmp; key=$(rootpxe_multicast_artifact_key "$key") || return 1; paths=$(rootpxe_multicast_artifact_paths "$root" "$rel") || return 1; tmp=$m.tmp
 jq -c --arg key "$key" --argjson paths "$(printf '%s\n' "$paths"|jq -R .|jq -s .)" '.+[{artifactKey:$key,paths:$paths}]' "$m" >"$tmp" || return 1; chmod 600 "$tmp" && mv "$tmp" "$m"
}
rootpxe_multicast_non_data_partition() { local t=${1,,} f=${2,,}; t=${t#0x}; t=${t#0}; [[ $f == swap || $t == 5 || $t == f || $t == 85 || $t == 82 || $t == 8200 || $t == 657fd6d-a4ab-43c4-84e5-0933c84b4f4f ]]; }
rootpxe_multicast_build_manifest() {
 local root=$1 a rel d n t f; rootpxe_multicast_manifest_begin || return 1
 case ${imgType:-} in
 n|N) [[ -r ${originalSchemaFile:-} && ! -L ${originalSchemaFile:-} ]] || return 1; while IFS= read -r a; do a=${a//$'\r'/}; [[ -n $a ]] || continue; rel=$(rootpxe_multicast_artifact_key "$a") || return 1; rootpxe_multicast_manifest_add "$rootpxe_multicast_manifest_file" "$rel" "$root" "$rel" || return 1; done < <(jq -er '(.partitions[]? | select((.fs? // "") != "swap" and (.role? // "") != "lvm_pv" and (.role? // "") != "swap") | .artifact // empty),(.lvm.vgs[]?.lvs[]? | select((.fs? // "") != "swap" and (.role? // "") != "swap") | .artifact // empty)' "$originalSchemaFile");;
 dd) rel=$(rootpxe_multicast_artifact_key "${img:-}") || return 1; rootpxe_multicast_manifest_add "$rootpxe_multicast_manifest_file" "$rel" "$root" "$rel" || return 1;;
 mps|mpa) [[ -r ${partitionInventoryFile:-} && ! -L ${partitionInventoryFile:-} ]] || return 1; while IFS=$'\t' read -r d n t f; do f=${f//$'\r'/}; [[ $d =~ ^[1-9][0-9]*$ && $n =~ ^[1-9][0-9]*$ ]] || return 1; [[ ${imgPartitionType:-all} == all || ${imgPartitionType:-all} == "$n" ]] || continue; rootpxe_multicast_non_data_partition "$t" "$f" && continue; rel=d${d}p${n}.img; rootpxe_multicast_manifest_add "$rootpxe_multicast_manifest_file" "$rel" "$root" "$rel" || return 1; done < <(jq -er '.disks[]|.number as $d|.partitions[]|[$d,.number,.typeGuid,.fs]|@tsv' "$partitionInventoryFile");;
 *) return 1;; esac
 jq -e 'length>0 and ([.[].artifactKey]|unique|length)==length and ([.[].paths[]]|unique|length)==([.[].paths[]]|length)' "$rootpxe_multicast_manifest_file" >/dev/null && (( $(wc -c <"$rootpxe_multicast_manifest_file") <= 65536 ))
}
rootpxe_multicast_runtime_begin() {
 local fifo=$1
 [[ $fifo == /tmp/pigz1 && -p $fifo ]] || return 1
 rootpxe_multicast_runtime_active=yes
 rootpxe_multicast_fifo=$fifo
}
rootpxe_multicast_stop_runtime() {
 local p n live
[[ ${rootpxe_multicast_runtime_active:-no} == yes ]] || return 0
for p in "${rootpxe_multicast_monitor_pid:-}" "${rootpxe_multicast_receiver_pid:-}" "${rootpxe_multicast_decoder_pid:-}" "${rootpxe_multicast_decompressor_pid:-}"; do
 [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" >/dev/null 2>&1 && kill "$p" >/dev/null 2>&1 || true
done
 for ((n=0; n<5; n++)); do
  live=no
  for p in "${rootpxe_multicast_monitor_pid:-}" "${rootpxe_multicast_receiver_pid:-}" "${rootpxe_multicast_decoder_pid:-}" "${rootpxe_multicast_decompressor_pid:-}"; do
   [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" >/dev/null 2>&1 && live=yes
  done
  [[ $live == no ]] && break
  sleep 1
 done
 for p in "${rootpxe_multicast_monitor_pid:-}" "${rootpxe_multicast_receiver_pid:-}" "${rootpxe_multicast_decoder_pid:-}" "${rootpxe_multicast_decompressor_pid:-}"; do
  [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" >/dev/null 2>&1 && kill -KILL "$p" >/dev/null 2>&1 || true
 done
 if [[ ${rootpxe_multicast_monitor_dir:-} == /tmp/rootpxe-multicast-monitor.* && -r ${rootpxe_multicast_monitor_dir:-}/curl.pid ]]; then
  read -r p <"$rootpxe_multicast_monitor_dir/curl.pid"
  [[ $p =~ ^[0-9]+$ ]] && kill "$p" >/dev/null 2>&1 || true
 fi
for p in "${rootpxe_multicast_monitor_pid:-}" "${rootpxe_multicast_receiver_pid:-}" "${rootpxe_multicast_decoder_pid:-}" "${rootpxe_multicast_decompressor_pid:-}"; do
 [[ $p =~ ^[0-9]+$ ]] && wait "$p" >/dev/null 2>&1 || true
done
 if declare -F rootpxe_partclone_progress_abort >/dev/null 2>&1; then
  rootpxe_partclone_progress_abort >/dev/null 2>&1 || true
 fi
 [[ ${rootpxe_multicast_fifo:-} == /tmp/pigz1 && -p ${rootpxe_multicast_fifo:-} ]] && rm -f -- "$rootpxe_multicast_fifo" || true
 [[ ${rootpxe_multicast_decoder_fifo:-} == /tmp/rootpxe-multicast-decode.* && -p ${rootpxe_multicast_decoder_fifo:-} ]] && rm -f -- "$rootpxe_multicast_decoder_fifo" || true
 [[ ${rootpxe_multicast_monitor_dir:-} == /tmp/rootpxe-multicast-monitor.* ]] && rm -rf -- "$rootpxe_multicast_monitor_dir" || true
 rm -f -- "${rootpxe_multicast_monitor_failure_file:-}"
 unset rootpxe_multicast_runtime_active rootpxe_multicast_fifo rootpxe_multicast_monitor_pid rootpxe_multicast_receiver_pid rootpxe_multicast_decoder_pid rootpxe_multicast_decompressor_pid rootpxe_multicast_decoder_fifo rootpxe_multicast_monitor_failure_file rootpxe_multicast_monitor_dir
}
rootpxe_multicast_reset_attempt() { rootpxe_multicast_stop_runtime; rm -f -- "${rootpxe_multicast_manifest_file:-}" "${rootpxe_multicast_context_file:-}" "${rootpxe_multicast_secret_file:-}" "${rootpxe_multicast_response_file:-}"; unset rootpxe_multicast_manifest_file rootpxe_multicast_context_file rootpxe_multicast_secret_file rootpxe_multicast_response_file rootpxe_multicast_group_id rootpxe_multicast_sequence rootpxe_multicast_completed; }
rootpxe_multicast_context_begin() {
 local token=${task_token:-${execution_token:-}}; [[ ${taskid:-} =~ ^[1-9][0-9]*$ && -n $token && -n ${mac:-} && ${progress_attempt:-1} =~ ^[0-9]+$ ]] || return 1
 umask 077; rootpxe_multicast_secret_file=$(mktemp /tmp/rootpxe-multicast-token.XXXXXX) || return 1; printf %s "$token" >"$rootpxe_multicast_secret_file"; chmod 600 "$rootpxe_multicast_secret_file" || return 1; rootpxe_multicast_context_file=$(mktemp /tmp/rootpxe-multicast-context.XXXXXX) || return 1
 jq -cn --argjson taskId "$taskid" --rawfile token "$rootpxe_multicast_secret_file" --arg mac "$mac" --argjson progressAttempt "${progress_attempt:-1}" '{taskId:$taskId,executionToken:$token,mac:$mac,progressAttempt:$progressAttempt}' >"$rootpxe_multicast_context_file" && chmod 600 "$rootpxe_multicast_context_file"
}
rootpxe_multicast_http_post() {
 local op=$1 req=$2 status limit=${rootpxe_multicast_ready_deadline:-300} deadline response remaining max_time connect_time; [[ $op == cancel ]] && limit=5; [[ $op =~ ^(join|prepare|ready|report|status|end|cancel)$ && -r $req && ! -L $req && $limit =~ ^[1-9][0-9]*$ ]] || return 1; (( $(wc -c <"$req") <= 65536 )) || return 1; deadline=$((SECONDS+limit)); [[ ${rootpxe_multicast_operation_deadline:-} =~ ^[0-9]+$ && $rootpxe_multicast_operation_deadline -lt $deadline ]] && deadline=$rootpxe_multicast_operation_deadline
 umask 077; if [[ ${rootpxe_multicast_monitor_dir:-} == /tmp/rootpxe-multicast-monitor.* ]]; then response=$(mktemp "$rootpxe_multicast_monitor_dir/response.XXXXXX"); else response=$(mktemp /tmp/rootpxe-multicast-response.XXXXXX); fi || return 1; chmod 600 "$response" || return 1
 while :; do remaining=$((deadline-SECONDS)); ((remaining>0)) || { rm -f -- "$response"; return 1; }; max_time=$((remaining<30?remaining:30)); connect_time=$((max_time<10?max_time:10)); if [[ ${rootpxe_multicast_monitor_dir:-} == /tmp/rootpxe-multicast-monitor.* ]]; then curl -sS --connect-timeout "$connect_time" --max-time "$max_time" -H 'Content-Type: application/json' --data-binary @"$req" -o "$response" -w '%{http_code}' "${rootpxe_api}multicast/$op" >"$rootpxe_multicast_monitor_dir/http-status" 2>/dev/null & rootpxe_multicast_http_pid=$!; printf '%s\n' "$rootpxe_multicast_http_pid" >"$rootpxe_multicast_monitor_dir/curl.pid"; while kill -0 "$rootpxe_multicast_http_pid" >/dev/null 2>&1; do sleep 1; done; wait "$rootpxe_multicast_http_pid" || { rm -f -- "$response"; return 1; }; status=$(cat "$rootpxe_multicast_monitor_dir/http-status"); rm -f -- "$rootpxe_multicast_monitor_dir/curl.pid" "$rootpxe_multicast_monitor_dir/http-status"; else status=$(curl -sS --connect-timeout "$connect_time" --max-time "$max_time" -H 'Content-Type: application/json' --data-binary @"$req" -o "$response" -w '%{http_code}' "${rootpxe_api}multicast/$op" 2>/dev/null) || { rm -f -- "$response"; return 1; }; fi
 if [[ $status == 409 ]] && jq -e '.code=="multicast_wait" and .retryAfterSec==1' "$response" >/dev/null 2>&1 && ((SECONDS<deadline)); then sleep 1; continue; fi
 [[ $status =~ ^2[0-9][0-9]$ ]] && jq -e 'type=="object"' "$response" >/dev/null 2>&1 || { rm -f -- "$response"; return 1; }; rm -f -- "${rootpxe_multicast_response_file:-}"; rootpxe_multicast_response_file=$response; return 0; done
}
rootpxe_multicast_request() { local op=$1 filter=$2 file; shift 2; umask 077; if [[ ${rootpxe_multicast_monitor_dir:-} == /tmp/rootpxe-multicast-monitor.* ]]; then file=$(mktemp "$rootpxe_multicast_monitor_dir/body.XXXXXX"); else file=$(mktemp /tmp/rootpxe-multicast-body.XXXXXX); fi || return 1; jq -cn --slurpfile common "$rootpxe_multicast_context_file" "$@" "$filter" >"$file" || { rm -f -- "$file"; return 1; }; chmod 600 "$file" || return 1; rootpxe_multicast_http_post "$op" "$file"; local rc=$?; rm -f -- "$file"; return $rc; }
rootpxe_multicast_join() {
 [[ ${multicastTransportMode:-} == multicast && ${taskType:-} == deploy && -r ${rootpxe_multicast_manifest_file:-} ]] || return 1; rootpxe_multicast_context_begin || return 1
 rootpxe_multicast_request join '($common[0]+{manifest:$manifest[0]})' --slurpfile manifest "$rootpxe_multicast_manifest_file" || return 1
 IFS=$'\t' read -r rootpxe_multicast_group_id rootpxe_multicast_join_window_sec rootpxe_multicast_ready_timeout_sec < <(jq -r '[.groupId,.joinWindowSec,.readyTimeoutSec]|@tsv' "$rootpxe_multicast_response_file"|tr -d '\r') || return 1
 [[ $rootpxe_multicast_group_id =~ ^[0-9A-Fa-f]{32}-[0-9A-Fa-f]{32}$ && $rootpxe_multicast_join_window_sec =~ ^[1-9][0-9]{0,3}$ && $rootpxe_multicast_ready_timeout_sec =~ ^[1-9][0-9]{0,4}$ ]] && ((rootpxe_multicast_join_window_sec<=3600&&rootpxe_multicast_ready_timeout_sec<=86400)) || return 1; rootpxe_multicast_sequence=0
}
rootpxe_multicast_ipv4() { local IFS=. a b c d; read -r a b c d <<<"$1"; [[ $a =~ ^[0-9]{1,3}$ && $b =~ ^[0-9]{1,3}$ && $c =~ ^[0-9]{1,3}$ && $d =~ ^[0-9]{1,3}$ ]] && ((a<=255&&b<=255&&c<=255&&d<=255)); }
rootpxe_multicast_prepare_stream() {
 local key next data gid seq; key=$(rootpxe_multicast_artifact_key "$1") || return 1; jq -e --arg k "$key" 'any(.[];.artifactKey==$k)' "$rootpxe_multicast_manifest_file" >/dev/null || return 1; next=$((rootpxe_multicast_sequence+1))
 rootpxe_multicast_request prepare '($common[0]+{groupId:$groupId,sequence:$sequence,artifactKey:$artifactKey})' --arg groupId "$rootpxe_multicast_group_id" --argjson sequence "$next" --arg artifactKey "$key" || return 1
 data=$(jq -r '[.groupId,.streamId,.sequence,.portBase,.multicastAddress,.ttl,.senderAddress]|@tsv' "$rootpxe_multicast_response_file"|tr -d '\r') || return 1; IFS=$'\t' read -r gid rootpxe_multicast_stream_id seq rootpxe_multicast_port_base rootpxe_multicast_address rootpxe_multicast_ttl rootpxe_multicast_sender_address <<<"$data"
 [[ $gid == "$rootpxe_multicast_group_id" && $seq == "$next" && $rootpxe_multicast_stream_id =~ ^[0-9A-Fa-f]{32}$ && $rootpxe_multicast_port_base =~ ^[0-9]+$ && $rootpxe_multicast_ttl =~ ^[0-9]+$ ]] && ((rootpxe_multicast_port_base>=1&&rootpxe_multicast_port_base<=65534&&rootpxe_multicast_port_base%2==0&&rootpxe_multicast_ttl>=1&&rootpxe_multicast_ttl<=255)) || return 1
 rootpxe_multicast_ipv4 "$rootpxe_multicast_address" && rootpxe_multicast_ipv4 "$rootpxe_multicast_sender_address" || return 1; local first=${rootpxe_multicast_address%%.*}; ((first>=224&&first<=239)) || return 1; rootpxe_multicast_sequence=$next
}
rootpxe_multicast_ready() { rootpxe_multicast_request ready '($common[0]+{streamId:$streamId,sequence:$sequence})' --arg streamId "$rootpxe_multicast_stream_id" --argjson sequence "$rootpxe_multicast_sequence"; }
rootpxe_multicast_report() { rootpxe_multicast_request report '($common[0]+{streamId:$streamId,sequence:$sequence,success:$success})' --arg streamId "$rootpxe_multicast_stream_id" --argjson sequence "$rootpxe_multicast_sequence" --argjson success "$1"; }
rootpxe_multicast_status() { rootpxe_multicast_request status '($common[0]+{groupId:$groupId})' --arg groupId "$rootpxe_multicast_group_id"; }
rootpxe_multicast_status_monitor() {
 local p=$1
 unset rootpxe_multicast_response_file
 trap 'rm -f -- "${rootpxe_multicast_response_file:-}"' EXIT
 while kill -0 "$p" >/dev/null 2>&1; do
  rootpxe_multicast_status && jq -e '(.state|type=="string") and (.errorCode?==null or .errorCode=="")' "$rootpxe_multicast_response_file" >/dev/null || {
   [[ ${rootpxe_multicast_monitor_failure_file:-} == /tmp/rootpxe-multicast-monitor.* ]] && printf '%s\n' controller_status_failed >"$rootpxe_multicast_monitor_failure_file"
   kill "$p" >/dev/null 2>&1 || true
   return 1
  }
  sleep 1
 done
}
rootpxe_multicast_wait_sequence() { local t=${rootpxe_multicast_ready_timeout_sec:-300} deadline c state rootpxe_multicast_operation_deadline; [[ $t =~ ^[1-9][0-9]*$ ]] || return 1; deadline=$((SECONDS+t)); rootpxe_multicast_operation_deadline=$deadline; while ((SECONDS<deadline)); do rootpxe_multicast_status || return 1; state=$(jq -r '.state//""' "$rootpxe_multicast_response_file"|tr -d '\r') || return 1; [[ $state != failed && $state != cancelled ]] || return 1; c=$(jq -r .currentSequence "$rootpxe_multicast_response_file"|tr -d '\r') || return 1; [[ $c =~ ^[0-9]+$ ]] && ((c>rootpxe_multicast_sequence)) && return 0; sleep 1; done; return 1; }
rootpxe_multicast_cancel() { [[ -n ${rootpxe_multicast_group_id:-} && -r ${rootpxe_multicast_context_file:-} ]] || return 0; rootpxe_multicast_request cancel '($common[0]+{groupId:$groupId})' --arg groupId "$rootpxe_multicast_group_id"; }
rootpxe_multicast_end() { local t=${rootpxe_multicast_ready_timeout_sec:-300} deadline done rootpxe_multicast_operation_deadline; [[ $t =~ ^[1-9][0-9]*$ ]] || return 1; deadline=$((SECONDS+t)); rootpxe_multicast_operation_deadline=$deadline; while ((SECONDS<deadline)); do rootpxe_multicast_request end '($common[0]+{groupId:$groupId})' --arg groupId "$rootpxe_multicast_group_id" || return 1; done=$(jq -r '.completed//false' "$rootpxe_multicast_response_file"|tr -d '\r') || return 1; [[ $done == true ]] && { rootpxe_multicast_completed=yes; return 0; }; sleep 1; done; return 1; }
rootpxe_multicast_cleanup() { rootpxe_multicast_stop_runtime; [[ ${rootpxe_multicast_completed:-no} == yes ]] || rootpxe_multicast_cancel >/dev/null 2>&1 || true; rootpxe_multicast_reset_attempt; }
