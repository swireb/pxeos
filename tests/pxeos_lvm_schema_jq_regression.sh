#!/usr/bin/env bash
# Verify the production LVM capture-schema jq program with the real jq binary.
# Command-flow mocks elsewhere must not hide a jq parser failure in this commit
# marker, because capture may already have produced LV payloads at that point.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
funcs="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/funcs.sh"
real_jq="$(command -v jq)" || { echo 'FAIL: host jq is required' >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Extract the actual quoted filter passed to `jq -n --rawfile lvs`; do not
# duplicate it here, otherwise a future source edit could make this test pass
# while production is still syntactically invalid.
filter="$({
    awk '
        /^[[:space:]]*jq -n .*--rawfile lvs / { capture=1; next }
        capture {
            if (sub(/'\'' >"\$stage\/d1\.lvm\.schema\.json".*/, "")) {
                print
                exit
            }
            print
        }
    ' "$funcs"
})"
[[ -n $filter ]] || fail 'unable to extract production LVM schema jq filter'

run_schema() {
    local input="$1" output="$2" input_for_jq
    input_for_jq="$(cygpath -w "$input" 2>/dev/null || printf '%s' "$input")"
    MSYS_NO_PATHCONV=1 "$real_jq" -n \
        --arg pv_uuid pv-uuid --arg vg_uuid vg-uuid --arg vg_name vg0 \
        --arg pv_artifact d1p1.lvm.pv.meta --arg vg_artifact d1p1.lvm.vg.cfg \
        --argjson part 1 --argjson pv_bytes 107374182400 --argjson pv_min 107374182400 \
        --argjson pe_start 1048576 --argjson extent 4194304 --argjson free 0 \
        --rawfile lvs "$input_for_jq" "$filter" >"$output"
}

cat >"$tmp/with-swap.tsv" <<'EOF'
root|lv-root|60700000000|60700000000|xfs|d1p1.lvm.lv.root.img|
var|lv-var|21400000000|21400000000|xfs|d1p1.lvm.lv.var.img|
swap|lv-swap|2147483648|2147483648|swap||swap-uuid
EOF
run_schema "$tmp/with-swap.tsv" "$tmp/with-swap.json" || fail 'production jq filter must compile and generate a data+swap schema'
MSYS_NO_PATHCONV=1 "$real_jq" -e '
  .version == 1 and .captureMode == "per_lv" and
  (.vgs|length) == 1 and (.vgs[0].lvs|length) == 3 and
  ([.vgs[0].lvs[] | select(.fs != "swap") | has("filesystemUuid") | not] | all) and
  ([.vgs[0].lvs[] | select(.fs == "swap" and .swapUuid == "swap-uuid" and .artifact == "")] | length) == 1
' "$(cygpath -w "$tmp/with-swap.json" 2>/dev/null || printf '%s' "$tmp/with-swap.json")" >/dev/null || fail 'generated data+swap schema contract is invalid'

cat >"$tmp/no-swap.tsv" <<'EOF'
root|lv-root|60700000000|60700000000|xfs|d1p1.lvm.lv.root.img|
home|lv-home|21400000000|21400000000|ext4|d1p1.lvm.lv.home.img|
EOF
run_schema "$tmp/no-swap.tsv" "$tmp/no-swap.json" || fail 'production jq filter must generate a multi-LV no-swap schema'
MSYS_NO_PATHCONV=1 "$real_jq" -e '
  (.vgs[0].lvs|length) == 2 and
  ([.vgs[0].lvs[] | select(.fs == "swap")] | length) == 0 and
  ([.vgs[0].lvs[] | has("filesystemUuid") | not] | all)
' "$(cygpath -w "$tmp/no-swap.json" 2>/dev/null || printf '%s' "$tmp/no-swap.json")" >/dev/null || fail 'generated no-swap schema contract is invalid'

printf 'PASS: PXEOS production LVM schema jq regression\n'
