#!/usr/bin/env bash
# PXEOS 分区安全回归：仅使用临时文件和 PATH mock，绝不触碰真实块设备。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
partition_funcs="$overlay/usr/share/pxeos/lib/partition-funcs.sh"
processor="$overlay/usr/share/pxeos/lib/procsfdisk.awk"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
must_have() { grep -Fq -- "$2" "$1" || fail "$1 缺少 $2"; }
must_not_call_format() { [[ ! -e "$tmp/nvme-format.log" ]] || fail "拒绝路径意外调用 nvme format"; }

# 先对实现边界作静态断言；随后用 gawk 与 mock nvme 进行行为验证。
must_have "$funcs" 'validateImageSectorSize()'
must_have "$funcs" 'rootpxe_nvme_reformat_to_sector_size()'
must_have "$funcs" 'rootpxe_disk_permit_granted'
must_have "$funcs" 'nvme format "$disk" --lbaf="$lbaf" --force'
must_have "$partition_funcs" 'LOGICAL_SECTOR_SIZE'
must_have "$partition_funcs" 'blockdev --getss'
must_have "$processor" 'by_partition_number'
must_have "$processor" 'disk_end = int(diskSize) - int(firstlba)'
must_have "$processor" 'if (rc != 0)'

cat >"$tmp/gpt-4kn.sfdisk" <<'EOF'
label: gpt
label-id: 11111111-1111-1111-1111-111111111111
device: /dev/nvme0n1
unit: sectors
first-lba: 34
last-lba: 262109
sector-size: 4096

/dev/nvme0n1p1 : start=        2048, size=         256, type=21686148-6449-6e6f-744e-656564454649
/dev/nvme0n1p2 : start=        4096, size=        8192, type=0fc63daf-8483-4772-8e79-3d69d8477de4
/dev/nvme0n1p10 : start=       12288, size=        8192, type=0fc63daf-8483-4772-8e79-3d69d8477de4
EOF
gawk -v action=filldisk -v target=/dev/nvme0n1 -v sizePos=262144 \
    -v diskSize=262144 -v SECTOR_SIZE=64 -v LOGICAL_SECTOR_SIZE=4096 \
    -v CHUNK_SIZE=4096 -v MIN_START=2048 -v fixedList=1 \
    -f "$processor" "$tmp/gpt-4kn.sfdisk" >"$tmp/gpt-output"
grep -Fq '/dev/nvme0n1p1 : start=' "$tmp/gpt-output" || fail '4Kn GPT 输出缺少小分区'
grep -Eq '/dev/nvme0n1p1 : start=[[:space:]]*[0-9]+, size=[[:space:]]*256,' "$tmp/gpt-output" || fail '4Kn 小分区被错误舍入为 0'
p2_line=$(grep -n '/dev/nvme0n1p2 : ' "$tmp/gpt-output" | cut -d: -f1)
p10_line=$(grep -n '/dev/nvme0n1p10 : ' "$tmp/gpt-output" | cut -d: -f1)
[[ $p2_line -lt $p10_line ]] || fail '分区自然排序错误：p10 不得排在 p2 前'
last_end=$(awk -F'[,= ]+' '/\/dev\/nvme0n1p10/{for(i=1;i<=NF;i++){if($i=="start")s=$(i+1);if($i=="size")z=$(i+1)}; print s+z}' "$tmp/gpt-output")
[[ $last_end -le 262110 ]] || fail 'GPT 最后分区覆盖备份 GPT 区域'

cat >"$tmp/overlap.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors

/dev/sda1 : start=        2048, size=       10000, type=83
/dev/sda2 : start=        3000, size=       10000, type=83
EOF
if gawk -v action=filldisk -v target=/dev/sda -v sizePos=50000 -v diskSize=50000 \
    -v SECTOR_SIZE=512 -v LOGICAL_SECTOR_SIZE=512 -v CHUNK_SIZE=512 -v MIN_START=2048 \
    -f "$processor" "$tmp/overlap.sfdisk" >/dev/null 2>&1; then
    fail '重叠分区表未 fail loud'
fi

cat >"$tmp/mbr-extended.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors

/dev/sda1 : start=        2048, size=        4096, Id=83
/dev/sda2 : start=        6144, size=       70000, Id=0x85
/dev/sda5 : start=        6146, size=       20000, Id=83
/dev/sda6 : start=       28146, size=       20000, Id=82
EOF
gawk -v action=filldisk -v target=/dev/sda -v sizePos=100000 -v diskSize=100000 \
    -v SECTOR_SIZE=512 -v LOGICAL_SECTOR_SIZE=512 -v CHUNK_SIZE=512 -v MIN_START=2048 \
    -v fixedList=1 -f "$processor" "$tmp/mbr-extended.sfdisk" >"$tmp/mbr-output"
p1_line=$(grep -n '/dev/sda1 : ' "$tmp/mbr-output" | cut -d: -f1)
p2_line=$(grep -n '/dev/sda2 : ' "$tmp/mbr-output" | cut -d: -f1)
p5_line=$(grep -n '/dev/sda5 : ' "$tmp/mbr-output" | cut -d: -f1)
p6_line=$(grep -n '/dev/sda6 : ' "$tmp/mbr-output" | cut -d: -f1)
[[ $p1_line -lt $p2_line && $p2_line -lt $p5_line && $p5_line -lt $p6_line ]] || fail 'MBR/逻辑分区输出未按稳定分区号排序'
p2_start=$(awk -F'[,= ]+' '/\/dev\/sda2 :/{for(i=1;i<=NF;i++)if($i=="start")print $(i+1)}' "$tmp/mbr-output")
p5_start=$(awk -F'[,= ]+' '/\/dev\/sda5 :/{for(i=1;i<=NF;i++)if($i=="start")print $(i+1)}' "$tmp/mbr-output")
[[ $p5_start -gt $p2_start ]] || fail '逻辑分区没有位于扩展容器内'

# MBR extended/EBR golden: sfdisk consumes the table line-by-line, so the
# container must precede all logical partitions even when p10/p11 are present.
cat >"$tmp/mbr-extended-10.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors

/dev/sda1 : start=        2048, size=        4096, Id=83
/dev/sda2 : start=        6144, size=      180000, Id=5
/dev/sda5 : start=        6146, size=       16000, Id=83
/dev/sda6 : start=       24146, size=       16000, Id=83
/dev/sda10 : start=      42146, size=       16000, Id=83
/dev/sda11 : start=      60146, size=       16000, Id=82
EOF
gawk -v action=filldisk -v target=/dev/sda -v sizePos=220000 -v diskSize=220000 \
    -v SECTOR_SIZE=512 -v LOGICAL_SECTOR_SIZE=512 -v CHUNK_SIZE=512 -v MIN_START=2048 \
    -v fixedList=1 -f "$processor" "$tmp/mbr-extended-10.sfdisk" >"$tmp/mbr-extended-10-output" 2>"$tmp/mbr-extended-10-error" || {
        cat "$tmp/mbr-extended-10-output" >&2
        cat "$tmp/mbr-extended-10-error" >&2
        fail 'MBR p10/p11 golden 生成失败'
    }
for number in 1 2 5 6 10 11; do
    grep -Fq "/dev/sda${number} :" "$tmp/mbr-extended-10-output" || fail "MBR 逻辑分区 p${number} 丢失"
done
p2_line=$(grep -n '/dev/sda2 : ' "$tmp/mbr-extended-10-output" | cut -d: -f1)
p5_line=$(grep -n '/dev/sda5 : ' "$tmp/mbr-extended-10-output" | cut -d: -f1)
p10_line=$(grep -n '/dev/sda10 : ' "$tmp/mbr-extended-10-output" | cut -d: -f1)
p11_line=$(grep -n '/dev/sda11 : ' "$tmp/mbr-extended-10-output" | cut -d: -f1)
[[ $p2_line -lt $p5_line && $p5_line -lt $p10_line && $p10_line -lt $p11_line ]] || fail 'MBR 扩展容器/逻辑分区未按数字顺序输出'
p2_start=$(awk -F'[,= ]+' '/\/dev\/sda2 :/{for(i=1;i<=NF;i++)if($i=="start")print $(i+1)}' "$tmp/mbr-extended-10-output")
p2_size=$(awk -F'[,= ]+' '/\/dev\/sda2 :/{for(i=1;i<=NF;i++)if($i=="size")print $(i+1)}' "$tmp/mbr-extended-10-output")
for number in 5 6 10 11; do
    logical_start=$(awk -F'[,= ]+' -v n="$number" '$0 ~ ("/dev/sda" n " :"){for(i=1;i<=NF;i++)if($i=="start")print $(i+1)}' "$tmp/mbr-extended-10-output")
    logical_size=$(awk -F'[,= ]+' -v n="$number" '$0 ~ ("/dev/sda" n " :"){for(i=1;i<=NF;i++)if($i=="size")print $(i+1)}' "$tmp/mbr-extended-10-output")
    [[ $logical_start -ge $((p2_start + 2)) && $((logical_start + logical_size)) -le $((p2_start + p2_size)) ]] || fail "逻辑分区 p${number} 未保留 EBR 间隔或越出容器"
done

# fixedList is an exact partition-number list: fixed 1 must never make p10
# fixed just because its decimal representation contains "1".
p10_original=16000
p10_resolved=$(awk -F'[,= ]+' '/\/dev\/sda10 :/{for(i=1;i<=NF;i++)if($i=="size")print $(i+1)}' "$tmp/mbr-extended-10-output")
[[ $p10_resolved -ne $p10_original ]] || fail 'fixedList=1 错误匹配了 p10'

# Reject malformed EBR graphs before a generated table can reach sfdisk.
for fixture in mbr-two-extended mbr-primary-overlaps-extended mbr-logical-without-parent mbr-logical-outside mbr-logical-overlap mbr-logical-no-ebr-gap; do
    case $fixture in
        mbr-two-extended) cat >"$tmp/$fixture.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
/dev/sda1 : start=2048, size=1000, Id=5
/dev/sda2 : start=5000, size=1000, Id=f
/dev/sda5 : start=2050, size=500, Id=83
EOF
            ;;
        mbr-logical-without-parent) cat >"$tmp/$fixture.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
/dev/sda1 : start=2048, size=1000, Id=83
/dev/sda5 : start=5000, size=500, Id=83
EOF
            ;;
        mbr-primary-overlaps-extended) cat >"$tmp/$fixture.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
/dev/sda1 : start=2048, size=5000, Id=5
/dev/sda2 : start=3000, size=1000, Id=83
/dev/sda5 : start=2050, size=500, Id=83
EOF
            ;;
        mbr-logical-outside) cat >"$tmp/$fixture.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
/dev/sda1 : start=2048, size=1000, Id=5
/dev/sda5 : start=4000, size=500, Id=83
EOF
            ;;
        mbr-logical-overlap) cat >"$tmp/$fixture.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
/dev/sda1 : start=2048, size=5000, Id=5
/dev/sda5 : start=2050, size=2000, Id=83
/dev/sda6 : start=3000, size=2000, Id=83
EOF
            ;;
        mbr-logical-no-ebr-gap) cat >"$tmp/$fixture.sfdisk" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
/dev/sda1 : start=2048, size=5000, Id=5
/dev/sda5 : start=2048, size=2000, Id=83
EOF
            ;;
    esac
    if gawk -v action=filldisk -v target=/dev/sda -v sizePos=20000 -v diskSize=20000 \
        -v SECTOR_SIZE=512 -v LOGICAL_SECTOR_SIZE=512 -v CHUNK_SIZE=512 -v MIN_START=2048 \
        -f "$processor" "$tmp/$fixture.sfdisk" >/dev/null 2>&1; then
        fail "不安全 MBR/EBR fixture 未被拒绝：$fixture"
    fi
done

mkdir -p "$tmp/mock"
cat >"$tmp/mock/nvme" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  id-ns) printf '%s\n' "${MOCK_NVME_ID_NS:-}" ;;
  format)
    printf '%s\n' "$*" >>"$MOCK_FORMAT_LOG"
    exit "${MOCK_NVME_FORMAT_RC:-0}"
    ;;
  *) exit 64 ;;
esac
EOF
cat >"$tmp/mock/blockdev" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --getss)
    if [[ -n ${MOCK_SECTOR_SEQUENCE:-} ]]; then
      index=0
      [[ -r ${MOCK_SECTOR_STATE:-} ]] && index=$(cat "$MOCK_SECTOR_STATE")
      IFS=, read -r -a values <<<"$MOCK_SECTOR_SEQUENCE"
      [[ $index -ge ${#values[@]} ]] && index=$((${#values[@]} - 1))
      printf '%s' $((index + 1)) >"$MOCK_SECTOR_STATE"
      printf '%s\n' "${values[$index]}"
    else
      printf '%s\n' "${MOCK_SECTOR_AFTER:-4096}"
    fi
    ;;
  --getsz) printf '%s\n' 262144 ;;
  --getpbsz) printf '%s\n' 4096 ;;
  *) exit 64 ;;
esac
EOF
cat >"$tmp/mock/udevadm" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  info) printf 'ID_WWN=nvme-test-wwn\nID_SERIAL=nvme-test-serial\n' ;;
  settle) exit 0 ;;
  *) exit 64 ;;
esac
EOF
cat >"$tmp/mock/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/mock"/*

# funcs.sh 在设备端按绝对路径 source 分区库和读取 /proc/cmdline；测试时均改到临时路径。
: >"$tmp/proc-cmdline"
sed -e "s|^\. /usr/share/pxeos/lib/partition-funcs.sh|. \"$partition_funcs\"|" \
    -e "s|</proc/cmdline|<\"$tmp/proc-cmdline\"|" "$funcs" >"$tmp/funcs.sh"
export PATH="$tmp/mock:$PATH"
export ismajordebug=0
# shellcheck disable=SC1090
. "$tmp/funcs.sh"

run_nvme() {
    local expected_id="$1"
    MOCK_FORMAT_LOG="$tmp/nvme-format.log"
    export MOCK_FORMAT_LOG
    rootpxe_disk_permit_granted=yes
    rootpxe_disk_permit_target_id="$expected_id"
    rootpxe_disk_permit_operation='nvme_format+deploy_write'
    PXEOS_NVME_FORMAT_COUNTDOWN_SEC=0
    PXEOS_NVME_REENUM_DEVICE=/dev/nvme0n1
    export rootpxe_disk_permit_granted rootpxe_disk_permit_target_id rootpxe_disk_permit_operation PXEOS_NVME_FORMAT_COUNTDOWN_SEC PXEOS_NVME_REENUM_DEVICE
    rootpxe_nvme_reformat_to_sector_size /dev/nvme0n1 4096 "$expected_id"
}

MOCK_NVME_ID_NS=$'lbaf  0 : ms:0   lbads:9 rp:0x2 (in use)\nlbaf  1 : ms:0   lbads:12 rp:0x2'
MOCK_SECTOR_AFTER=4096
export MOCK_NVME_ID_NS MOCK_SECTOR_AFTER
run_nvme nvme-test-wwn
grep -Fq -- '--lbaf=1 --force' "$tmp/nvme-format.log" || fail '未选择 metadata-free 匹配 LBAF'

# validateImageSectorSize 覆盖两个方向：512 -> 4096 及 4096 -> 512。
cat >"$tmp/image-4kn.sfdisk" <<'EOF'
label: gpt
sector-size: 4096
EOF
MOCK_SECTOR_SEQUENCE=512,512,4096
MOCK_SECTOR_STATE="$tmp/sector-state"
export MOCK_SECTOR_SEQUENCE MOCK_SECTOR_STATE
rm -f "$MOCK_SECTOR_STATE" "$tmp/nvme-format.log"
rootpxe_disk_permit_granted=yes
rootpxe_disk_permit_target_id=nvme-test-wwn
rootpxe_disk_permit_operation='nvme_format+deploy_write'
PXEOS_NVME_FORMAT_COUNTDOWN_SEC=0
PXEOS_NVME_REENUM_DEVICE=/dev/nvme0n1
export rootpxe_disk_permit_granted rootpxe_disk_permit_target_id rootpxe_disk_permit_operation PXEOS_NVME_FORMAT_COUNTDOWN_SEC PXEOS_NVME_REENUM_DEVICE
validateImageSectorSize /dev/nvme0n1 "$tmp/image-4kn.sfdisk"
grep -Fq -- '--lbaf=1 --force' "$tmp/nvme-format.log" || fail '512 -> 4096 未选择 4Kn LBAF'

cat >"$tmp/image-512.sfdisk" <<'EOF'
label: gpt
sector-size: 512
EOF
MOCK_SECTOR_SEQUENCE=4096,4096,512
rm -f "$MOCK_SECTOR_STATE" "$tmp/nvme-format.log"
validateImageSectorSize /dev/nvme0n1 "$tmp/image-512.sfdisk"
grep -Fq -- '--lbaf=0 --force' "$tmp/nvme-format.log" || fail '4096 -> 512 未选择 512 LBAF'
unset MOCK_SECTOR_SEQUENCE MOCK_SECTOR_STATE

rm -f "$tmp/nvme-format.log"
MOCK_NVME_ID_NS='lbaf  1 : ms:8   lbads:12 rp:0x2'
export MOCK_NVME_ID_NS
if run_nvme nvme-test-wwn; then fail '仅 metadata LBAF 被错误接受'; fi
must_not_call_format

MOCK_NVME_ID_NS='lbaf  0 : ms:0   lbads:9 rp:0x2'
export MOCK_NVME_ID_NS
if run_nvme nvme-test-wwn; then fail '无匹配 LBAF 被错误接受'; fi
must_not_call_format

MOCK_NVME_ID_NS='lbaf  1 : ms:0   lbads:12 rp:0x2'
export MOCK_NVME_ID_NS
rootpxe_disk_permit_granted=no
export rootpxe_disk_permit_granted
if rootpxe_nvme_reformat_to_sector_size /dev/nvme0n1 4096 nvme-test-wwn; then fail '无 permit 被错误接受'; fi
must_not_call_format

rootpxe_disk_permit_granted=yes
rootpxe_disk_permit_target_id=other-disk
export rootpxe_disk_permit_granted rootpxe_disk_permit_target_id
if rootpxe_nvme_reformat_to_sector_size /dev/nvme0n1 4096 nvme-test-wwn; then fail '错误磁盘绑定被错误接受'; fi
must_not_call_format

rootpxe_disk_permit_target_id=nvme-test-wwn
export rootpxe_disk_permit_target_id
if rootpxe_nvme_reformat_to_sector_size /dev/sda 4096 nvme-test-wwn; then fail '非 NVMe 被错误接受'; fi
must_not_call_format

MOCK_NVME_FORMAT_RC=1
export MOCK_NVME_FORMAT_RC
if run_nvme nvme-test-wwn; then fail 'format 失败被错误接受'; fi
unset MOCK_NVME_FORMAT_RC
[[ -e "$tmp/nvme-format.log" ]] || fail 'format 失败路径没有实际调用格式化命令'
rm -f "$tmp/nvme-format.log"

MOCK_SECTOR_AFTER=512
export MOCK_SECTOR_AFTER
if run_nvme nvme-test-wwn; then fail '重枚举回读不匹配被错误接受'; fi
[[ -e "$tmp/nvme-format.log" ]] || fail '回读失败路径没有实际调用格式化命令'
rm -f "$tmp/nvme-format.log"

MOCK_SECTOR_AFTER=4096
export MOCK_SECTOR_AFTER
read() { reply=c; return 0; }
PXEOS_NVME_FORMAT_COUNTDOWN_SEC=1
export PXEOS_NVME_FORMAT_COUNTDOWN_SEC
if rootpxe_nvme_reformat_to_sector_size /dev/nvme0n1 4096 nvme-test-wwn; then fail '取消格式化被错误接受'; fi
unset -f read
must_not_call_format

printf 'PASS: PXEOS partition regression contract\n'
