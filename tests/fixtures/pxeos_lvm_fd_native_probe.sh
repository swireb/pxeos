#!/usr/bin/env bash
# Explicit opt-in diagnostic: readonly LVM queries and private RAM markers only.
set -euo pipefail
umask 077
helper=${1:?narrow helper required}; probe_dir=${2:?private evidence directory required}
[[ $probe_dir == /tmp/rootpxe-lvm-fd-fix.* && -d $probe_dir && ! -L $probe_dir && -O $probe_dir && $(stat -c %a "$probe_dir") == 700 ]] || exit 90
[[ -f $helper && ! -L $helper && -O $helper ]] || exit 91
. "$helper"
probe_file=$(umask 077; mktemp "$probe_dir/native-pin.XXXXXX")
chmod 600 "$probe_file"
probe_identity=$(stat -c '%d:%i:%a' "$probe_file")
probe_pin=''; probe_foreign=''
cleanup(){
    [[ -z $probe_foreign ]] || rootpxe_log_pin_release "$probe_foreign" "$probe_identity" || true
    [[ -z $probe_pin ]] || rootpxe_log_pin_release "$probe_pin" "$probe_identity" || true
    rootpxe_log_raw_cleanup "$probe_file" "$probe_identity" || true
}
trap cleanup EXIT
fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
exec {probe_pin}<"$probe_file"
rootpxe_log_pin_register "$probe_pin" "$probe_identity"
printf 'OWNED_PIN=%s ' "$probe_pin"; grep '^flags:' "/proc/self/fdinfo/$probe_pin"
LC_ALL=C pvs --reportformat json -o pv_name,pv_uuid,vg_name,vg_uuid >"$probe_dir/direct-pvs.json" 2>"$probe_dir/direct-pvs.err"
grep -Fq "File descriptor $probe_pin ($probe_file) leaked" "$probe_dir/direct-pvs.err" || fail direct-pin-warning-not-reproduced
for tool in pvs vgs; do
    if [[ $tool == pvs ]]; then fields=pv_name,pv_uuid,vg_name,vg_uuid; else fields=vg_name,vg_uuid; fi
    rc=0; LC_ALL=C rootpxe_lvm_native "$tool" --reportformat json -o "$fields" >"$probe_dir/isolated-$tool.json" 2>"$probe_dir/isolated-$tool.err" || rc=$?
    [[ $rc == 0 && ! -s $probe_dir/isolated-$tool.err ]] || fail isolated-query
    jq -e '.report|type=="array" and length==1' "$probe_dir/isolated-$tool.json" >/dev/null || fail native-json
    rootpxe_log_pin_readonly "$probe_pin" "$probe_identity" || fail parent-pin-closed
    printf 'PASS: native %s rc=%s stderr=empty parent-pin=valid\n' "$tool" "$rc"
done
saved_release=$(declare -f rootpxe_log_pin_release)
rootpxe_log_pin_release(){ return 1; }
rc=0; LC_ALL=C rootpxe_lvm_native pvs --reportformat json -o pv_name >"$probe_dir/release-fault.json" 2>"$probe_dir/release-fault.err" || rc=$?
[[ $rc == 0 ]] || fail release-fault-replaced-native-rc
grep -Fq "File descriptor $probe_pin ($probe_file) leaked" "$probe_dir/release-fault.err" || fail release-fault-native-skipped
eval "$saved_release"
rootpxe_log_pin_readonly "$probe_pin" "$probe_identity" || fail release-fault-parent-pin
printf 'PASS: release failure keeps native rc and real leak warning\n'
exec {probe_foreign}<"$probe_file"
LC_ALL=C rootpxe_lvm_native pvs --reportformat json -o pv_name >"$probe_dir/foreign.json" 2>"$probe_dir/foreign.err"
grep -Fq "File descriptor $probe_foreign ($probe_file) leaked" "$probe_dir/foreign.err" || fail foreign-same-inode-closed
! grep -Fq "File descriptor $probe_pin ($probe_file) leaked" "$probe_dir/foreign.err" || fail owned-pin-inherited
rootpxe_log_pin_release "$probe_foreign" "$probe_identity"; probe_foreign=''
exec {probe_foreign}<>"$probe_file"
rc=0; rootpxe_log_pin_register "$probe_foreign" "$probe_identity" || rc=$?
[[ $rc != 0 ]] || fail writable-pin-registered
rootpxe_log_owned_pin_state[$probe_foreign]=$probe_identity
LC_ALL=C rootpxe_lvm_native pvs --reportformat json -o pv_name >"$probe_dir/writable.json" 2>"$probe_dir/writable.err"
grep -Fq "File descriptor $probe_foreign ($probe_file) leaked" "$probe_dir/writable.err" || fail writable-pin-closed
rootpxe_log_pin_release "$probe_foreign" "$probe_identity"; probe_foreign=''
printf 'PASS: foreign same-inode and writable FD warnings remain visible\n'
for kind in return exit; do
    for expected in 0 7; do
        marker="$probe_dir/trap-$kind-$expected.$BASHPID"
        (
            trap 'printf "OUTER\n" >>"$marker"' EXIT HUP INT TERM
            before=$(trap -p EXIT HUP INT TERM)
            pvs(){ if [[ $kind == exit ]]; then exit "$expected"; fi; return "$expected"; }
            rc=0; rootpxe_lvm_native pvs || rc=$?
            [[ $rc == "$expected" && $(trap -p EXIT HUP INT TERM) == "$before" && ! -e $marker ]] || fail child-trap
            rootpxe_log_pin_readonly "$probe_pin" "$probe_identity" || fail trap-parent-pin
        )
        [[ $(wc -l <"$marker") == 1 ]] || fail outer-trap-count
    done
done
printf 'PASS: native Bash child return/exit 0/7 preserves parent traps\n'
printf 'Native LVM FD probe: PASS\n'
