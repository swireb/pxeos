#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
multicast="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
write=$(awk '/^writeImage\(\)/ {on=1} on {print} on && /^}$/ {exit}' "$funcs")
[[ -n $write && -r $multicast ]] || exit 1
case_run() (
  name=$1
  fifo="$tmp/$name.fifo"
  trace="$tmp/$name.trace"
  export trace
  eval "$(sed "s|/tmp/pigz1|$fifo|g" "$multicast")"
  eval "$(printf '%s\n' "$write" | sed "s|/tmp/pigz1|$fifo|g")"
  rootpxe_validate_runtime_img_format(){ :; }
  rootpxe_partclone_progress_start(){ echo progress_start >>"$trace"; }
  rootpxe_partclone_progress_wait(){ echo progress_wait >>"$trace"; :; }
  rootpxe_partclone_progress_abort(){ echo progress_abort >>"$trace"; :; }
  rootpxe_console_message(){ :; }
  rootpxe_partition_progress_item(){ :; }
  rootpxe_partition_progress_current_item(){ :; }
  handleError(){ echo handle >>"$trace"; exit 90; }
  rootpxe_multicast_key_from_restore_source(){ echo d1p1.img; }
  rootpxe_multicast_prepare_stream(){ [[ $name != prepare_fail ]]; }
  rootpxe_multicast_ready(){ [[ $name != ready_fail ]]; }
  rootpxe_multicast_report(){
    echo "report:$1" >>"$trace"
    [[ $name != report_fail || $1 != true ]]
  }
  rootpxe_multicast_wait_sequence(){ [[ $name != sequence_fail ]]; }
  rootpxe_multicast_cancel(){ echo cancel >>"$trace"; :; }
  rootpxe_multicast_status_monitor(){
    echo "$BASHPID" >"$tmp/$name.monitor.pid"
    if [[ $name == monitor_fail ]]; then
      sleep 0.1
      printf '%s\n' controller_status_failed >"$rootpxe_multicast_monitor_failure_file"
      kill "$1" >/dev/null 2>&1 || true
      return 1
    fi
    while kill -0 "$1" >/dev/null 2>&1; do sleep 1; done
  }
  partclone.restore(){
    echo "$BASHPID" >"$tmp/$name.decoder.pid"
    [[ $name != decoder_early && $name != decoder_early_compressed ]] || return 7
    cat >/dev/null
  }
  udp-receiver(){
    trap 'echo receiver_exit >>"$trace"' EXIT
    [[ $name != signal ]] || trap '' TERM
    echo "$BASHPID" >"$tmp/$name.receiver.pid"
    echo receiver_start >>"$trace"
    printf x
    [[ $name != receiver_fail ]] || return 7
    case $name in
      decoder_early|decoder_early_compressed|monitor_fail|signal) while :; do sleep 1; done ;;
    esac
  }
  pigz(){ echo "$BASHPID" >"$tmp/$name.decompressor.pid"; cat <&0; }
  zstdmt(){ echo "$BASHPID" >"$tmp/$name.decompressor.pid"; cat <&0; }
  printf x >"$tmp/d1p1.img"
  storage=mock img=mock imgFormat=3 imgLegacy= imagePath="$tmp"
  case $name in decoder_early_compressed|signal) imgFormat=0 ;; esac
  rootpxe_partclone_progress_term=xterm
  rootpxe_partclone_progress_args=()
  rootpxe_partclone_progress_stderr_target="$tmp/$name.stderr"
  rootpxe_multicast_port_base=9000
  rootpxe_multicast_address=239.1.2.3
  rootpxe_multicast_ttl=32
  rootpxe_multicast_ready_timeout_sec=1
  rootpxe_multicast_join_window_sec=1
  if [[ $name == signal ]]; then
    echo "$BASHPID" >"$tmp/signal.case.pid"
    trap 'echo cleanup >>"$trace"; rootpxe_multicast_cleanup; exit 143' TERM
  fi
  if [[ $name == unicast ]]; then
    writeImage "$tmp/d1p1.img" "$tmp/target" no
  else
    writeImage "$tmp/d1p1.img" "$tmp/target" yes
  fi
)
pid_is_dead() {
  local file=$1 pid
  [[ -s $file ]] || return 0
  read -r pid <"$file"
  ! kill -0 "$pid" >/dev/null 2>&1
}
check() {
  local name=$1 want=$2 rc
  case_run "$name"
  rc=$?
  [[ $rc == "$want" && ! -e "$tmp/$name.fifo" ]] || { echo "FAIL:$name:$rc"; exit 1; }
  pid_is_dead "$tmp/$name.receiver.pid" || { echo "FAIL:$name:receiver_alive"; exit 1; }
  pid_is_dead "$tmp/$name.decoder.pid" || { echo "FAIL:$name:decoder_alive"; exit 1; }
  pid_is_dead "$tmp/$name.decompressor.pid" || { echo "FAIL:$name:decompressor_alive"; exit 1; }
  pid_is_dead "$tmp/$name.monitor.pid" || { echo "FAIL:$name:monitor_alive"; exit 1; }
}
check_signal() {
  local pid rc i killer
  (
    for ((i=0; i<50; i++)); do [[ -s "$tmp/signal.case.pid" && -s "$tmp/signal.receiver.pid" ]] && break; sleep 0.1; done
    [[ -s "$tmp/signal.case.pid" && -s "$tmp/signal.receiver.pid" ]] || exit 1
    read -r pid <"$tmp/signal.case.pid"
    kill -TERM "$pid"
  ) &
  killer=$!
  case_run signal
  rc=$?
  wait "$killer" || { echo FAIL:signal:killer; exit 1; }
  [[ $rc == 143 ]] || { echo "FAIL:signal:exit:$rc"; exit 1; }
  [[ ! -e "$tmp/signal.fifo" ]] || { cat "$tmp/signal.trace"; echo FAIL:signal:fifo_remains; exit 1; }
  pid_is_dead "$tmp/signal.receiver.pid" || { echo FAIL:signal:receiver_alive; exit 1; }
  pid_is_dead "$tmp/signal.decoder.pid" || { echo FAIL:signal:decoder_alive; exit 1; }
  pid_is_dead "$tmp/signal.decompressor.pid" || { echo FAIL:signal:decompressor_alive; exit 1; }
  pid_is_dead "$tmp/signal.monitor.pid" || { echo FAIL:signal:monitor_alive; exit 1; }
}
set +e
check unicast 0
check success 0
check receiver_fail 90
check decoder_early 90
check decoder_early_compressed 90
check prepare_fail 90
check ready_fail 90
check report_fail 90
check monitor_fail 90
check sequence_fail 90
check_signal
set -e
grep -Fq 'report:false' "$tmp/decoder_early.trace"
grep -Fq cancel "$tmp/decoder_early.trace"
grep -Fq 'report:true' "$tmp/report_fail.trace"
grep -Fq cancel "$tmp/report_fail.trace"
grep -Fq 'report:false' "$tmp/monitor_fail.trace"
grep -Fq cancel "$tmp/monitor_fail.trace"
grep -Fq progress_abort "$tmp/ready_fail.trace"
echo 'PASS: multicast writeImage mock regression'
