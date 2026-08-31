#!/usr/bin/env bash
# 合并后的 PXEOS 回归测试；每个原脚本在独立子 shell 中运行。
set -euo pipefail

# ===== 原脚本：tests/pxeos_partition_regression.sh =====
(
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
read() {
    if [[ $* == '-r -t 1 -n 1 reply' ]]; then
        reply=c
        return 0
    fi
    builtin read "$@"
}
PXEOS_NVME_FORMAT_COUNTDOWN_SEC=1
export PXEOS_NVME_FORMAT_COUNTDOWN_SEC
if rootpxe_nvme_reformat_to_sector_size /dev/nvme0n1 4096 nvme-test-wwn; then fail '取消格式化被错误接受'; fi
unset -f read
must_not_call_format

printf 'PASS: PXEOS partition regression contract\n'
)
# ===== 原脚本结束：tests/pxeos_partition_regression.sh =====

# ===== 原脚本：tests/pxeos_partition_inventory_regression.sh =====
(
# Uses the installed jq and only temporary command stubs; no host disk is read.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "real jq required"
mkdir -p "$tmp/bin" "$tmp/capture"
cat >"$tmp/bin/blockdev" <<'EOF'
#!/usr/bin/env bash
case "$1:$2" in
  --getss:*) echo 512;; --getpbsz:*) echo 512;;
  --getsize64:/dev/nvme0n1) echo 1073741824;; --getsize64:/dev/sda) echo 536870912;;
  *) exit 1;; esac
EOF
cat >"$tmp/bin/blkid" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
case "$last:$2" in
  /dev/nvme0n1p1:TYPE) echo vfat;; /dev/nvme0n1p1:UUID) echo efi-uuid;; /dev/nvme0n1p1:PARTUUID) echo efi-partuuid;;
  /dev/sda1:TYPE) echo xfs;; /dev/sda1:UUID) echo data-uuid;; /dev/sda1:PARTUUID) echo data-partuuid;;
esac
EOF
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH"
: >"$tmp/proc-cmdline"
sed -e "s|/usr/share/pxeos|$overlay/usr/share/pxeos|g" -e "s|</proc/cmdline|<\"$tmp/proc-cmdline\"|" "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
# shellcheck disable=SC1090
ismajordebug=0; . "$tmp/funcs.sh"
getPartitions() { case "$1" in /dev/nvme0n1) parts='/dev/nvme0n1p1';; /dev/sda) parts='/dev/sda1';; *) parts='';; esac; }
cat >"$tmp/capture/d1.partitions" <<'EOF'
label: gpt
device: /dev/nvme0n1
unit: sectors
sector-size: 512
/dev/nvme0n1p1 : start=        2048, size=     1024000, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
EOF
rootpxe_build_partition_inventory "$tmp/capture" mps /dev/nvme0n1 "" || fail mps
jq -e '.version == 1 and (.disks|length)==1 and .disks[0].partitions[0].fs == "vfat" and .disks[0].partitions[0].uuid == "efi-uuid"' "$rootpxe_partition_inventory_file" >/dev/null || fail mps-facts
# This exercises the real jq invocation in the n schema builder with no LVM
# rawfile supplied.  The canonical d1.partitions is the sole source layout;
# no shrunken/minimum sidecar is created for the new n contract.
: >"$tmp/capture/d1p1.img"
rootpxe_build_original_schema /dev/nvme0n1 "$tmp/capture" || fail n-schema-real-jq
jq -e '.partitionTable == "gpt" and .partitions[0].fs == "vfat" and .minDeployBytes == .originalDiskBytes and (.partitions | all(.minSectors == .originalSectors))' "$rootpxe_original_schema_file" >/dev/null || fail n-schema-facts
[[ ! -e "$tmp/capture/d1.minimum.partitions" && ! -e "$tmp/capture/d1.original.partitions" && ! -e "$tmp/capture/d1.shrunken.partitions" ]] || fail n-schema-must-not-read-legacy-layouts
# An MBR extended container may contain unused tail sectors after its last
# logical partition.  d1.partitions is both the captured and minimum layout,
# so Schema v2 must retain the container's captured size instead of deriving a
# smaller minimum from the last logical partition.
cp "$tmp/capture/d1.partitions" "$tmp/capture/d1.gpt.partitions"
cat >"$tmp/capture/d1.partitions" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
sector-size: 512
/dev/sda1 : start=        2048, size=        1024, type=83
/dev/sda2 : start=        4096, size=       10000, type=5
/dev/sda5 : start=        4098, size=        1000, type=83
/dev/sda6 : start=        6100, size=        1000, type=83
EOF
: >"$tmp/capture/d1p1.img"
: >"$tmp/capture/d1p5.img"
: >"$tmp/capture/d1p6.img"
rootpxe_build_original_schema /dev/sda "$tmp/capture" || fail mbr-extended-tail-schema
jq -e '.version == 2 and .partitionTable == "mbr" and .minDeployBytes == .originalDiskBytes and ([.partitions[] | select(.kind == "extended") | .originalSectors == 10000 and .minSectors == .originalSectors] | length) == 1 and (.partitions | all(.minSectors == .originalSectors))' "$rootpxe_original_schema_file" >/dev/null || fail mbr-extended-tail-must-keep-captured-minimum
mv "$tmp/capture/d1.gpt.partitions" "$tmp/capture/d1.partitions"
# Exercise the production LVM layout resolver with the real jq binary too.
# The separate LVM suite intentionally replaces jq to focus on command-flow
# failures, so it cannot detect jq syntax or result-shape regressions here.
cat >"$tmp/lvm-schema.json" <<'EOF'
{"version":2,"logicalSectorBytes":512,"lvm":{"version":1,"captureMode":"per_lv","resizePolicy":"grow_only","pvs":[{"partitionNumber":1,"uuid":"pv-1","vgUuid":"vg-1","originalBytes":268435456,"minBytes":268435456,"peStartBytes":1048576,"artifact":"d1p1.lvm.pv.meta","vgConfigArtifact":"d1p1.lvm.vg.cfg"}],"vgs":[{"name":"vg0","uuid":"vg-1","extentBytes":4194304,"pvPartitionNumbers":[1],"originalFreeBytes":0,"lvs":[{"name":"root","uuid":"lv-root","layout":"linear","originalBytes":67108864,"minBytes":67108864,"fs":"ext4","role":"data","resizable":true,"artifact":"d1p1.lvm.lv.root.img"}]}]}}
EOF
printf '%s\n' '{"lvm":[{"pvPartitionNumber":1,"freeSpacePolicy":"preserveOriginal","volumes":[{"uuid":"lv-root","mode":"original"}]}]}' >"$tmp/lvm-layout.json"
printf '%s\n' '[{"number":1,"resolvedSectors":524288}]' >"$tmp/lvm-partitions.json"
rootpxe_validate_lvm_deployment_layout "$tmp/lvm-schema.json" "$tmp/lvm-layout.json" "$tmp/lvm-partitions.json" || fail lvm-layout-real-jq
jq -e '.volumes|type == "array" and length == 1 and .[0].resolvedBytes == 67108864' "$rootpxe_resolved_lvm_layout_file" >/dev/null || fail lvm-layout-result-shape
cat >"$tmp/capture/d2.partitions" <<'EOF'
label: dos
device: /dev/sda
unit: sectors
sector-size: 512
/dev/sda1 : start=        2048, size=      524288, type=83
EOF
rootpxe_build_partition_inventory "$tmp/capture" mpa /dev/nvme0n1 "/dev/nvme0n1 /dev/sda" || fail mpa
jq -e '[.disks[].number] == [1,2] and .disks[0].partitionTable == "gpt" and .disks[1].partitionTable == "mbr"' "$rootpxe_partition_inventory_file" >/dev/null || fail mpa-order
rm -f "$tmp/capture/d1.partitions"
rootpxe_build_partition_inventory "$tmp/capture" dd /dev/nvme0n1 "" || fail dd
jq -e '.disks[0].partitionTable == "none" and (.disks[0].partitions|length)==0' "$rootpxe_partition_inventory_file" >/dev/null || fail dd-none
cat >"$tmp/capture/d1.partitions" <<'EOF'
label: gpt
device: /dev/nvme0n1
unit: sectors
sector-size: 512
EOF
rootpxe_build_partition_inventory "$tmp/capture" dd /dev/nvme0n1 "" || fail dd-empty-gpt
jq -e '.disks[0].partitionTable == "gpt" and (.disks[0].partitions|length)==0' "$rootpxe_partition_inventory_file" >/dev/null || fail dd-empty-gpt-facts
sed 's/^label: gpt$/label: dos/' "$tmp/capture/d1.partitions" >"$tmp/capture/d1.partitions.mbr"
mv "$tmp/capture/d1.partitions.mbr" "$tmp/capture/d1.partitions"
rootpxe_build_partition_inventory "$tmp/capture" dd /dev/nvme0n1 "" || fail dd-empty-mbr
jq -e '.disks[0].partitionTable == "mbr" and (.disks[0].partitions|length)==0' "$rootpxe_partition_inventory_file" >/dev/null || fail dd-empty-mbr-facts
# Run imgcomplete itself with only its callback/finalisation collaborators
# mocked.  Every successful capture type must submit the inventory, while n
# is the only one that additionally produces editable schema metadata.
for image_type in n mps mpa dd; do
  callback="$tmp/finish-$image_type.args"
  export callback
  type=up imgType="$image_type" hd=/dev/nvme0n1 disks='/dev/nvme0n1 /dev/sda' \
    taskid=42 task_token=token mac=aa:bb:cc:dd:ee:ff web=https://rootpxe.invalid/ \
    env -u rootpxe_original_schema_file -u rootpxe_partition_inventory_file bash -s -- "$overlay/bin/pxeos.imgcomplete" "$tmp" <<'EOF'
script=$1; test_tmp=$2
dmidecode() { printf '%s\n' test-uuid; }
rootpxe_require_task_context() { :; }
rootpxe_stage() { :; }
rootpxe_finalize_capture() { rootpxe_final_capture_path="$test_tmp/capture"; capture_size_bytes=8; }
rootpxe_build_partition_inventory() { rootpxe_partition_inventory_file="$test_tmp/inventory-${imgType}"; printf '%s\n' '{"version":1,"disks":[{"number":1,"sourceDevice":"/dev/mock","partitionTable":"none","originalDiskBytes":1,"logicalSectorBytes":1,"physicalSectorBytes":1,"partitions":[]}]}' >"$rootpxe_partition_inventory_file"; }
rootpxe_build_original_schema() { rootpxe_original_schema_file="$test_tmp/schema-${imgType}"; printf '%s\n' '{"version":1}' >"$rootpxe_original_schema_file"; }
rootpxe_clear_capture_marker() { :; }
rootpxe_cleanup_task_json() { :; }
rootpxe_console_message() { :; }
dots() { :; }
debugPause() { :; }
curl() { printf '%s\n' "$@" >"$callback"; printf '%s\n' '{"success":true}'; }
# shellcheck disable=SC1090
. "$script"
EOF
  grep -Fq 'partitionInventory={"version":1' "$callback" || fail "imgcomplete-$image_type-inventory"
  if [[ $image_type == n ]]; then
    grep -Fq 'originalSchema={"version":1}' "$callback" || fail imgcomplete-n-schema
  elif grep -Fq 'originalSchema=' "$callback"; then
    fail "imgcomplete-$image_type-fixed-schema"
  fi
done
echo 'PASS: PXEOS partition inventory regression'
)
# ===== 原脚本结束：tests/pxeos_partition_inventory_regression.sh =====

# ===== 原脚本：tests/pxeos_lvm_regression.sh =====
(
# Temporary command stubs only: this suite never accesses host LVM or disks.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
real_jq=$(command -v jq) || fail 'host jq is required for production LVM schema coverage'
mkdir -p "$tmp/bin" "$tmp/image"; export PATH="$tmp/bin:$PATH" LVM_TRACE="$tmp/trace"; : >"$LVM_TRACE"
cat >"$tmp/bin/pvs" <<'EOF'
#!/usr/bin/env bash
case " $* " in
 *' pv_name,pv_uuid,vg_name,vg_uuid,pv_size,pe_start '*) printf ' /dev/mock1 | pv-1 | vg0 | vg-1 | 268435456 | 1048576\n'; [[ ${PVS_FAIL:-0} != 1 ]] || exit 1; [[ ${LVM_MODE:-ok} != multi ]] || printf ' /dev/mock1 | pv-2 | vg0 | vg-1 | 268435456 | 1048576\n'; exit 0;;
 *' pv_name,vg_uuid '*) printf ' /dev/mock1 | vg-1\n'; [[ ${PVS_ALL_FAIL:-0} != 1 ]] || exit 1; [[ ${LVM_MODE:-ok} != cross ]] || printf ' /dev/foreign1 | vg-1\n'; exit 0;;
 *' pv_uuid '*) printf ' pv-1\n';;
esac
EOF
cat >"$tmp/bin/vgs" <<'EOF'
#!/usr/bin/env bash
printf ' vg0 | vg-1 | 4194304 | 0\n'; [[ ${VGS_FAIL:-0} != 1 ]] || exit 1
EOF
cat >"$tmp/bin/lvs" <<'EOF'
#!/usr/bin/env bash
printf ' root | lv-root | /dev/vg0/root | 67108864 | -wi-a----- | %s |  |  |  | \n' "${LVM_SEGTYPE:-linear}"
printf ' swap | lv-swap | /dev/vg0/swap | 33554432 | -wi-a----- | linear |  |  |  | \n'
[[ ${LVS_FAIL:-0} != 1 ]] || exit 1
EOF
cat >"$tmp/bin/blockdev" <<'EOF'
#!/usr/bin/env bash
case "$1" in --getsize64) case "$2" in /dev/mock1) echo 268435456;; /dev/vg0/root) [[ -f ${LVM_SIZE_STATE:-} ]] && cat "$LVM_SIZE_STATE" || echo 67108864;; /dev/vg0/swap) echo 33554432;; *) echo 209715200;; esac;; --getss|--getpbsz) echo 512;; *) exit 1;; esac
EOF
cat >"$tmp/bin/blkid" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
case " $* " in *' TYPE '*) [[ ${LVM_MODE:-ok} == crypt ]] && { echo crypto_LUKS; exit 0; }; [[ ${LVM_MODE:-ok} == mdraid ]] && { echo linux_raid_member; exit 0; }; [[ $last == /dev/vg0/swap ]] && echo swap || echo "${LVM_FS:-ext4}";; *' UUID '*) [[ $last == /dev/vg0/swap ]] && echo swap-uuid || echo root-uuid;; esac
EOF
cat >"$tmp/bin/pvdisplay" <<'EOF'
#!/usr/bin/env bash
echo "pvdisplay:$*" >>"$LVM_TRACE"
for arg in "$@"; do
  [[ $arg != --nosuffix ]] || { echo 'unsupported pvdisplay option: --nosuffix' >&2; exit 64; }
done
[[ ${PV_FAIL:-0} == 1 ]] && exit 1; echo 'PV UUID pv-1'
EOF
cat >"$tmp/bin/vgcfgbackup" <<'EOF'
#!/usr/bin/env bash
[[ ${VG_FAIL:-0} == 1 ]] && exit 1; while (($#)); do [[ $1 == -f ]] && { echo pv-1 >"$2"; exit 0; }; shift; done; exit 1
EOF
cat >"$tmp/bin/resize2fs" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -P ]] && { echo 'Estimated minimum size of the filesystem: 8192'; exit 0; }; echo "resize2fs:$*" >>"$LVM_TRACE"
EOF
cat >"$tmp/bin/dumpe2fs" <<'EOF'
#!/usr/bin/env bash
echo 'Block size:               4096'
EOF
for cmd in partclone.extfs partclone.xfs pvcreate vgcfgrestore pvresize vgchange lvextend mkswap e2fsck mount umount xfs_growfs; do
printf '#!/usr/bin/env bash\necho "%s:$*" >>"$LVM_TRACE"\nexit 0\n' "$cmd" >"$tmp/bin/$cmd"; chmod +x "$tmp/bin/$cmd"
done
cat >"$tmp/bin/lvextend" <<'EOF'
#!/usr/bin/env bash
echo "lvextend:$*" >>"$LVM_TRACE"; echo 67108864 >"$LVM_SIZE_STATE"
EOF
chmod +x "$tmp/bin/lvextend"
cat >"$tmp/bin/e2fsck" <<'EOF'
#!/usr/bin/env bash
echo "e2fsck:$*" >>"$LVM_TRACE"
exit "${E2FSCK_RC:-0}"
EOF
chmod +x "$tmp/bin/e2fsck"
cat >"$tmp/bin/jq" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ $args == *'--slurpfile schema'* ]]; then [[ ${LAYOUT_MODE:-ok} != belowmin ]] || exit 1; echo '{"pv":{"partitionNumber":1,"uuid":"pv-1","originalBytes":268435456,"artifact":"d1p1.lvm.pv.meta","vgConfigArtifact":"d1p1.lvm.vg.cfg"},"vg":{"name":"vg0","uuid":"vg-1","extentBytes":4194304},"pvBytes":268435456,"volumes":[{"name":"root","uuid":"lv-root","fs":"ext4","artifact":"d1p1.lvm.lv.root.img","resolvedBytes":67108864},{"name":"swap","uuid":"lv-swap","fs":"swap","artifact":"","swapUuid":"swap-uuid","resolvedBytes":33554432}]}'; exit 0; fi
if [[ $args == *'.volumes[]|.name,'* ]]; then
  [[ ${LVM_LIST_MODE:-ok} != fail ]] || exit 1
  [[ ${LVM_LIST_MODE:-ok} != empty ]] || exit 0
  artifact=${LVM_PIPE_ARTIFACT:+d1p1.lvm.lv.name\|safe.img}; artifact=${artifact:-d1p1.lvm.lv.root.img}
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' root lv-root ext4 "$artifact" 67108864 '' swap lv-swap swap '' 33554432 swap-uuid
  exit 0
fi
case "$args" in *'.pv.artifact'*) echo d1p1.lvm.pv.meta; exit 0;; *'.pv.vgConfigArtifact'*) echo d1p1.lvm.vg.cfg; exit 0;; esac
[[ $args == *'if has("lvm") then'* || $args == *'--argjson number'* ]] && exit 0
[[ $args == *'has("lvm")'* ]] && { [[ ${LVM_LEGACY_SCHEMA:-0} == 1 ]] && exit 1 || exit 0; }
if [[ $args == *'--rawfile lvs'* ]]; then [[ -n ${JQ_ARGS_LOG:-} ]] && printf '%s\n' "$args" >>"$JQ_ARGS_LOG"; echo '{"version":1,"captureMode":"per_lv","resizePolicy":"grow_only","pvs":[{"partitionNumber":1,"uuid":"pv-1","vgUuid":"vg-1","originalBytes":268435456,"minBytes":268435456,"peStartBytes":1048576,"artifact":"d1p1.lvm.pv.meta","vgConfigArtifact":"d1p1.lvm.vg.cfg"}],"vgs":[{"name":"vg0","uuid":"vg-1","extentBytes":4194304,"pvPartitionNumbers":[1],"originalFreeBytes":0,"lvs":[{"name":"root","uuid":"lv-root","layout":"linear","originalBytes":67108864,"minBytes":67108864,"fs":"ext4","role":"data","resizable":true,"artifact":"d1p1.lvm.lv.root.img"},{"name":"swap","uuid":"lv-swap","layout":"linear","originalBytes":33554432,"minBytes":33554432,"fs":"swap","role":"swap","resizable":false,"artifact":"","swapUuid":"swap-uuid"}]}]}'; exit 0; fi
EOF
chmod +x "$tmp/bin"/*
# funcs.sh imports kernel arguments at source time.  Redirect that read to an
# empty fixture so this mock-only suite never depends on the Windows host's
# missing /proc filesystem.
: >"$tmp/proc-cmdline"
sed -e "s|/usr/share/pxeos|$overlay/usr/share/pxeos|g" \
    -e "s|</proc/cmdline|<\"$tmp/proc-cmdline\"|" \
    "$overlay/usr/share/pxeos/lib/funcs.sh" >"$tmp/funcs.sh"
# shellcheck disable=SC1090
ismajordebug=0
. "$tmp/funcs.sh"
rootpxe_test_real_jq() {
    local arg converted=()
    for arg in "$@"; do
        [[ -e $arg ]] && converted+=("$(cygpath -w "$arg")") || converted+=("$arg")
    done
    MSYS_NO_PATHCONV=1 "$real_jq" "${converted[@]}"
}
rootpxe_lvm_json_jq() { rootpxe_test_real_jq "$@"; }
# The production trimmer uses sed, which makes this pure mock suite very slow
# under Git Bash on Windows.  Keep equivalent whitespace semantics locally so
# branch coverage is bounded without replacing any production command flow.
rootpxe_lvm_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}
# Keep the LVM command contract in-process. Git Bash process startup otherwise
# dominates this mock matrix and obscures whether a failure is handled by the
# production preflight rather than by the test runner timeout.
pvs() {
  case " $* " in
    *'reportformat json'*)
      [[ ${PVS_FAIL:-0} != 1 ]] || return 1
      [[ ${LVM_MODE:-ok} != badjson ]] || { printf '{bad json\n'; return 0; }
      [[ ${LVM_MODE:-ok} != none ]] || { printf '{"report":[{"pv":[]}]}\n'; return 0; }
      if [[ ${LVM_MODE:-ok} == multi ]]; then printf '{"report":[{"pv":[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"},{"pv_name":"/dev/mock2","pv_uuid":"pv-2","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"}]}]}\n';
      elif [[ ${LVM_MODE:-ok} == unassigned ]]; then printf '{"report":[{"pv":[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"","vg_uuid":"","pv_size":"268435456","pe_start":"1048576"}]}]}\n';
      elif [[ ${LVM_MODE:-ok} == cross ]]; then printf '{"report":[{"pv":[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"},{"pv_name":"/dev/foreign1","pv_uuid":"pv-2","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"}]}]}\n';
      else printf '{"report":[{"pv":[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1","pv_size":"268435456","pe_start":"1048576"}]}]}\n'; fi
      return 0 ;;
  esac
  return 0
}
vgs() { [[ ${VGS_FAIL:-0} != 1 ]] || return 1; [[ ${LVM_MODE:-ok} != bad-vgs-json ]] || { printf '{bad json\n'; return 0; }; printf '{"report":[{"vg":[{"vg_name":"vg0","vg_uuid":"vg-1","vg_extent_size":"4194304","vg_free":"0"}]}]}\n'; }
lvs() {
  [[ ${LVS_FAIL:-0} != 1 ]] || return 1
  [[ ${LVM_MODE:-ok} != bad-lvs-json ]] || { printf '{bad json\n'; return 0; }
  [[ ${LVM_MODE:-ok} != casefold ]] || { printf '{"report":[{"lv":[{"vg_name":"vg0","vg_uuid":"vg-1","lv_name":"root","lv_uuid":"lv-root","lv_path":"/dev/vg0/root","lv_size":"67108864","lv_attr":"-wi-a-----","segtype":"linear","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null},{"vg_name":"vg0","vg_uuid":"vg-1","lv_name":"ROOT","lv_uuid":"lv-root-upper","lv_path":"/dev/vg0/ROOT","lv_size":"67108864","lv_attr":"-wi-a-----","segtype":"linear","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null}]}]}\n'; return 0; }
  root='{"vg_name":"vg0","vg_uuid":"vg-1","lv_name":"root","lv_uuid":"lv-root","lv_path":"/dev/vg0/root","lv_size":"67108864","lv_attr":"-wi-a-----","segtype":"'"${LVM_SEGTYPE:-linear}"'","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null}'
  swap='{"vg_name":"vg0","vg_uuid":"vg-1","lv_name":"swap","lv_uuid":"lv-swap","lv_path":"/dev/vg0/swap","lv_size":"33554432","lv_attr":"-wi-a-----","segtype":"linear","origin":null,"pool_lv":null,"data_lv":null,"metadata_lv":null}'
  case " $* " in
    *' vg0/root '*) rows=$root ;;
    *' vg0/swap '*) rows=$swap ;;
    *) rows="$root,$swap" ;;
  esac
  printf '{"report":[{"lv":[%s]}]}\n' "$rows"
}
export LVM_SIZE_STATE="$tmp/lv-size"; echo 67108864 >"$LVM_SIZE_STATE"
getPartitions() { parts='/dev/mock1'; }
getPartitionNumber() { part_number=${1##*mock}; part_number=${part_number##*p}; }
uploadFormat() { [[ ${UPLOAD_FAIL:-0} != 1 ]] || return 1; : >"$2.000"; rootpxe_last_writer_pid=1; }
rootpxe_wait_for_writer() { [[ ${WRITER_FAIL:-0} != 1 ]]; }

# Legal preflight/capture executes real helper branches; it occurs before any permit.
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail legal-preflight
[[ $rootpxe_lvm_active == yes && $rootpxe_lvm_pv_number == 1 ]] || fail facts
rootpxe_lvm_storage_identifier 'vg+data' || fail plus-storage-identifier
rootpxe_lvm_storage_identifier 'vg:data' && fail colon-storage-identifier
rootpxe_lvm_storage_filename 'd1p1.lvm.lv.root+data.img' || fail plus-storage-filename
long_lvm_artifact=$(printf '%*s' 251 '' | tr ' ' a).img
rootpxe_lvm_storage_filename "$long_lvm_artifact" || fail long-storage-filename
rootpxe_lvm_storage_filename 'd1p1.lvm.lv.root:bad.img' && fail colon-storage-filename
rootpxe_lvm_storage_filename 'd1p1.lvm.lv.root|bad.img' && fail pipe-storage-filename
rootpxe_lvm_json_jq -n -e '"lv+root" | test("^[A-Za-z0-9._+-]{1,160}$")' >/dev/null || fail plus-lv-name-json-contract
export LVM_MODE=none
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail non-lvm-preflight
[[ ${rootpxe_lvm_active:-} == no && -z ${rootpxe_lvm_facts_file:-} && -z ${rootpxe_lvm_lv_facts_file:-} ]] || fail non-lvm-facts
unset LVM_MODE
for command_failure in PVS_FAIL VGS_FAIL LVS_FAIL; do
  export "$command_failure"=1
  rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail "$command_failure-process-substitution-hidden"
  [[ ${rootpxe_lvm_active:-no} != yes && -z ${rootpxe_lvm_facts_file:-} && -z ${rootpxe_lvm_lv_facts_file:-} ]] || fail "$command_failure-facts-not-cleaned"
  unset "$command_failure"
done
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail preflight-after-command-failure
export E2FSCK_RC=1; rootpxe_capture_lvm_volumes "$tmp/image" || fail legal-capture-e2fsck-fixed; unset E2FSCK_RC
[[ -s "$tmp/image/d1.lvm.schema.json" && -f "$tmp/image/d1p1.lvm.pv.meta" && -f "$tmp/image/d1p1.lvm.vg.cfg" && -f "$tmp/image/d1p1.lvm.lv.root.img" && ! -e "$tmp/image/d1p1.lvm.lv.swap.img" && ! -e "$tmp/image/d1.lv.lv-root.img" ]] || fail readable-lvm-artifacts
jq -e '.version == 1 and .captureMode == "per_lv" and .resizePolicy == "grow_only" and ([.vgs[].lvs[] | select(.fs == "swap" and .artifact != "")] | length) == 0' "$tmp/image/d1.lvm.schema.json" >/dev/null || fail lvm-v1-schema
! grep -Fq -- '--nosuffix' "$LVM_TRACE" || fail capture-must-not-use-unsupported-pvdisplay-option
grep -Fq 'partclone.extfs:' "$LVM_TRACE" || fail writer-not-run
grep -Fq 'vgchange:-ay --select vg_uuid=vg-1 vg0' "$LVM_TRACE" || fail capture-vg-not-activated
grep -Fq 'vgchange:-an --select vg_uuid=vg-1 vg0' "$LVM_TRACE" || fail capture-vg-not-deactivated
! grep -Fq 'lvextend:' "$LVM_TRACE" || fail n-capture-must-not-expand-source-lv

# The surrounding LVM suite uses a jq stub for its command-flow matrix.  Run
# this production capture branch once with the host jq binary so syntax errors
# in the real schema program cannot be hidden by the stub.
real_jq_image="$tmp/real-jq-image"; mkdir -p "$real_jq_image"
rootpxe_lvm_capture_preflight /dev/mock "$real_jq_image" || fail real-jq-preflight
jq() { rootpxe_test_real_jq "$@"; }
rootpxe_capture_lvm_volumes "$real_jq_image" || fail real-jq-schema-capture
unset -f jq
"$real_jq" -e '.version == 1 and .captureMode == "per_lv" and .resizePolicy == "grow_only" and (.pvs | length) == 1 and (.vgs | length) == 1' "$real_jq_image/d1.lvm.schema.json" >/dev/null || fail real-jq-schema-content

for bad_mode in badjson bad-vgs-json bad-lvs-json; do export LVM_MODE="$bad_mode"; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail "$bad_mode-must-reject"; unset LVM_MODE; done
export LVM_MODE=multi; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail multipv; unset LVM_MODE
export LVM_MODE=unassigned; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail unassigned-target-pv; unset LVM_MODE
export LVM_MODE=casefold; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail casefold-lv-name; unset LVM_MODE
rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" || fail facts-after-multipv
: >"$LVM_TRACE"; export PV_FAIL=1; rootpxe_capture_lvm_volumes "$tmp/image" && fail sidecar-failure; unset PV_FAIL
grep -Fq 'vgchange:-an --select vg_uuid=vg-1 vg0' "$LVM_TRACE" || fail failed-capture-vg-not-deactivated
export WRITER_FAIL=1; rootpxe_capture_lvm_volumes "$tmp/image" && fail writer-failure; unset WRITER_FAIL
: >"$LVM_TRACE"; export UPLOAD_FAIL=1; rootpxe_capture_lvm_volumes "$tmp/image" && fail upload-failure; unset UPLOAD_FAIL
export LVM_MODE=cross; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail cross-disk-vg; unset LVM_MODE
export LVM_SEGTYPE=thin; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail thin-topology; unset LVM_SEGTYPE
export LVM_MODE=crypt; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail crypt-topology; unset LVM_MODE
export LVM_MODE=mdraid; rootpxe_lvm_capture_preflight /dev/mock "$tmp/image" && fail mdraid-topology; unset LVM_MODE
grep -Fq '[[ $fs == xfs ]]' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail xfs-capture-branch
grep -Fq '.[4] != "swap"' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail xfs-growable-schema
grep -Fq 'xfs_growfs "$xfs_mount"' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail xfs-grow-branch
grep -Fq 'lvextend -y -L' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail lvm-grow-only-branch
grep -Fq 'rootpxe_lvm_json_jq() { command jq "$@"; }' "$overlay/usr/share/pxeos/lib/funcs.sh" || fail lvm-jq-must-not-be-environment-replaced
schema_publish_line=$(grep -n -F 'mv "$stage/d1.lvm.schema.json" "$image_path/d1.lvm.schema.json"' "$overlay/usr/share/pxeos/lib/funcs.sh" | cut -d: -f1)
sidecar_publish_line=$(grep -n -F 'mv "$stage/$vg_artifact" "$image_path/$vg_artifact"' "$overlay/usr/share/pxeos/lib/funcs.sh" | cut -d: -f1)
[[ $schema_publish_line =~ ^[0-9]+$ && $sidecar_publish_line =~ ^[0-9]+$ && $schema_publish_line -gt $sidecar_publish_line ]] || fail lvm-schema-must-publish-last

# Resolver produces an LVM plan with no LVM write command before permit.
printf '{"version":2,"lvm":{"version":1,"captureMode":"per_lv","resizePolicy":"grow_only"}}' >"$tmp/schema.json"; printf '{"lvm":[]}' >"$tmp/layout.json"; printf '[]' >"$tmp/partitions.json"; : >"$LVM_TRACE"
rootpxe_validate_lvm_deployment_layout "$tmp/schema.json" "$tmp/layout.json" "$tmp/partitions.json" || fail layout-plan
[[ ! -s "$LVM_TRACE" ]] || fail prepermit-write
jq() { rootpxe_test_real_jq "$@"; }
printf '{"version":2,"partitions":[{"fs":"LVM2_member","role":"lvm_pv"}]}' >"$tmp/legacy-lvm-schema.json"
rootpxe_validate_lvm_deployment_layout "$tmp/legacy-lvm-schema.json" "$tmp/layout.json" "$tmp/partitions.json" && fail raw-lvm-without-schema
unset -f jq
for mode in fixed percentage remaining; do export LAYOUT_MODE="$mode"; rootpxe_validate_lvm_deployment_layout "$tmp/schema.json" "$tmp/layout.json" "$tmp/partitions.json" || fail "layout-$mode"; unset LAYOUT_MODE; done
export LAYOUT_MODE=belowmin; rootpxe_validate_lvm_deployment_layout "$tmp/schema.json" "$tmp/layout.json" "$tmp/partitions.json" && fail layout-below-min; unset LAYOUT_MODE
node -e 'const extent=4194304,capacity=100*extent,min=9*extent,fixed=10*extent,pct=Math.floor(capacity*25/100/extent)*extent,remaining=capacity-fixed-pct;if(fixed<min||pct<=0||remaining<min)process.exit(1)' || fail layout-capacity-oracle

rootpxe_resolved_lvm_layout_file="$tmp/plan.json"; printf '{}' >"$rootpxe_resolved_lvm_layout_file"; rootpxe_disk_permit_granted=no
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail no-permit
[[ ! -s "$LVM_TRACE" ]] || fail no-permit-write
echo pv-1 >"$tmp/image/d1p1.lvm.pv.meta"; echo pv-1 >"$tmp/image/d1p1.lvm.vg.cfg"; : >"$tmp/image/d1p1.lvm.lv.root.img"
rootpxe_disk_stable_identity() { echo target-1; }; rootpxe_disk_permit_granted=yes; rootpxe_disk_permit_target_id=target-1; rootpxe_disk_permit_operation=deploy_write
writeImage() { echo "writeImage:$*" >>"$LVM_TRACE"; }
for list_mode in fail empty; do
  : >"$LVM_TRACE"; export LVM_LIST_MODE="$list_mode"
  rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail "lvm-list-$list_mode"
  [[ ! -s "$LVM_TRACE" ]] || fail "lvm-list-$list_mode-wrote-before-parse"
  unset LVM_LIST_MODE
done
cat >"$rootpxe_resolved_lvm_layout_file" <<'EOF'
{"pv":{"uuid":"pv-1","partitionNumber":1,"originalBytes":268435456,"artifact":"d1p1.lvm.pv.meta","vgConfigArtifact":"d1p1.lvm.vg.cfg"},"vg":{"name":"vg0","uuid":"vg-1","extentBytes":4194304},"pvBytes":268435456,"volumes":[{"name":"root","uuid":"lv-root","fs":"ext4","artifact":"d1p1.lvm.lv.root.img","resolvedBytes":67108864},{"name":"swap","uuid":"lv-swap","fs":"swap","artifact":"","swapUuid":"swap-uuid","resolvedBytes":33554432}]}
EOF
# The deployment identity checks intentionally exercise the production jq
# expressions, not the command-flow jq stub used above for malformed-list
# cases.
jq() { command "$real_jq" "$@"; }
# Deployment rechecks request a narrower pvs field set after capture.  Pin the
# fixture here so the assertion proves that exact JSON response rather than a
# prior capture-mode branch.
pvs() { printf '{"report":[{"pv":[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1"}]}]}\n'; }
pvs --reportformat json -o pv_name,pv_uuid,vg_name,vg_uuid /dev/mock1 | MSYS_NO_PATHCONV=1 "$real_jq" -e '.report[0].pv | length == 1 and .[0].pv_name == "/dev/mock1" and .[0].pv_uuid == "pv-1" and .[0].vg_name == "vg0" and .[0].vg_uuid == "vg-1"' >/dev/null || fail restore-pvs-json-fixture
restore_pvs_json=$(pvs --reportformat json -o pv_name,pv_uuid,vg_name,vg_uuid /dev/mock1)
rootpxe_lvm_json_jq -e --arg path /dev/mock1 --arg pv pv-1 --arg vg vg0 --arg vguuid vg-1 '(.report|type=="array" and length==1 and ((.[0].pv? // [])|type=="array") and ((.[0].pv? // [])|length==1) and .[0].pv[0].pv_name==$path and .[0].pv[0].pv_uuid==$pv and .[0].pv[0].vg_name==$vg and .[0].pv[0].vg_uuid==$vguuid)' <<<"$restore_pvs_json" >/dev/null || fail restore-pvs-json-production-expression
sed 's/"name":"swap","uuid":"lv-swap","fs":"swap","artifact":"","swapUuid":"swap-uuid","resolvedBytes":33554432/"name":"ROOT","uuid":"lv-root-upper","fs":"ext4","artifact":"d1p1.lvm.lv.root.img","resolvedBytes":33554432/' "$rootpxe_resolved_lvm_layout_file" >"$tmp/casefold-plan.json"
rootpxe_resolved_lvm_layout_file="$tmp/casefold-plan.json"; : >"$LVM_TRACE"
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail restore-casefold-lv-must-fail
[[ ! -s "$LVM_TRACE" ]] || fail restore-casefold-lv-wrote-before-validation
rootpxe_resolved_lvm_layout_file="$tmp/plan.json"
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock || fail permitted-restore
for marker in pvcreate vgcfgrestore writeImage; do grep -Fq "$marker:" "$LVM_TRACE" || fail "missing-$marker"; done
grep -Fq 'd1p1.lvm.lv.root.img' "$LVM_TRACE" || fail restore-readable-lv-artifact
pvs() { printf '{"report":[{"pv":[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"wrong-vg"}]}]}\n'; }
: >"$LVM_TRACE"
rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail restore-pv-vg-identity-must-fail
grep -Fq 'pvcreate:' "$LVM_TRACE" || fail restore-pv-vg-identity-did-not-reach-postcreate-check
! grep -Fq 'writeImage:' "$LVM_TRACE" || fail restore-pv-vg-identity-wrote-lv
grep -Fq 'vgchange:-an --select vg_uuid=vg-1 vg0' "$LVM_TRACE" || fail restore-pv-vg-identity-did-not-cleanup
pvs() { printf '{"report":[{"pv":[{"pv_name":"/dev/mock1","pv_uuid":"pv-1","vg_name":"vg0","vg_uuid":"vg-1"}]}]}\n'; }
sed 's/d1p1\.lvm\.lv\.root\.img/d1p1.lvm.lv.name|safe.img/' "$rootpxe_resolved_lvm_layout_file" >"$tmp/pipe-plan.json"
rootpxe_resolved_lvm_layout_file="$tmp/pipe-plan.json"; : >"$LVM_TRACE"; rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail pipe-artifact-must-reject
[[ ! -s "$LVM_TRACE" ]] || fail pipe-artifact-wrote-before-validation
sed 's/"pvBytes":268435456/"pvBytes":134217728/' "$rootpxe_resolved_lvm_layout_file" >"$tmp/small-plan.json"
rootpxe_resolved_lvm_layout_file="$tmp/small-plan.json"; : >"$LVM_TRACE"; rootpxe_restore_lvm_volumes "$tmp/image" /dev/mock && fail small-pv-must-fail
unset -f jq
echo 'PASS: PXEOS LVM behavior regression'
)
# ===== 原脚本结束：tests/pxeos_lvm_regression.sh =====

# ===== 原脚本：tests/pxeos_disk_identity_regression.sh =====
(
# Offline stable-disk-identity contract.  It extracts only identity and NVMe
# binding helpers, replacing udev, hashing and block probing with local mocks.
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

awk '/^rootpxe_disk_stable_identity\(\)/ { copy = 1 } /^rootpxe_nvme_permit_matches\(\)/ { exit } copy' "$funcs" >"$tmp/identity.sh"
awk '/^rootpxe_nvme_permit_matches\(\)/ { copy = 1 } /^rootpxe_nvme_find_metadata_free_lbaf\(\)/ { exit } copy' "$funcs" >"$tmp/permit-match.sh"
awk '/^rootpxe_nvme_wait_for_reenumeration\(\)/ { copy = 1 } /^rootpxe_nvme_reformat_to_sector_size\(\)/ { exit } copy' "$funcs" >"$tmp/reenumerate.sh"
[[ -s $tmp/identity.sh && -s $tmp/permit-match.sh && -s $tmp/reenumerate.sh ]] || fail 'identity helpers were not extracted'

identity_property=''
identity_udev_status=0
identity_hash_status=0
udevadm() {
    [[ $1 == info ]] || return 1
    [[ $identity_udev_status -eq 0 ]] || return "$identity_udev_status"
    printf '%s\n' "$identity_property"
}
sha256sum() {
    [[ $identity_hash_status -eq 0 ]] || return "$identity_hash_status"
    command sha256sum "$@"
}
. "$tmp/identity.sh"
. "$tmp/permit-match.sh"
. "$tmp/reenumerate.sh"

identity_for() {
    identity_property="$1"
    identity_udev_status=0
    identity_hash_status=0
    rootpxe_disk_stable_identity /dev/mockdisk
}

legal='wwn-0x5000c500a1b2c3d4'
[[ $(identity_for "ID_WWN=$legal") == "$legal" ]] || fail 'legal backend-compatible ID_WWN must remain unchanged'
legal_128=$(printf 'a%.0s' {1..128})
[[ $(identity_for "ID_SERIAL=$legal_128") == "$legal_128" ]] || fail 'legal 128-character ID_SERIAL must remain unchanged'
[[ $(identity_for $'ID_WWN=\nID_SERIAL=serial-42') == serial-42 ]] || fail 'empty preferred property must fall through to non-empty ID_SERIAL'
[[ $(identity_for $'ID_SERIAL=serial-first\nID_WWN=wwn-later') == serial-first ]] || fail 'first non-empty ID_SERIAL must keep existing udev output selection order'

for raw in 'serial with spaces' 'serial/with/slashes' 'serial=with=equals' 'disk-编号' "$(printf 'x%.0s' {1..129})" 'sha256:looks-like-an-encoded-id'; do
    first=$(identity_for "ID_WWN=$raw") || fail "invalid ID did not produce a hash: $raw"
    second=$(identity_for "ID_WWN=$raw") || fail "invalid ID was not stable: $raw"
    [[ $first =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid ID did not produce sha256 namespace: $raw"
    [[ $first == "$second" ]] || fail "same raw ID did not produce same stable identity: $raw"
    [[ $first != "$raw" ]] || fail "reserved sha256 prefix or invalid raw ID was returned verbatim: $raw"
done

space_hash=$(identity_for 'ID_WWN=serial with spaces')
slash_hash=$(identity_for 'ID_WWN=serial/with/slashes')
equals_hash=$(identity_for 'ID_WWN=serial=with=equals')
[[ $space_hash != "$slash_hash" && $space_hash != "$equals_hash" && $slash_hash != "$equals_hash" ]] || fail 'different raw IDs collided after normalization'
[[ $(identity_for 'ID_WWN=serial=one') != "$(identity_for 'ID_WWN=serial=two')" ]] || fail 'values after equals were truncated before hashing'
[[ $(identity_for 'ID_WWN= serial') != "$(identity_for 'ID_WWN=serial')" ]] || fail 'leading whitespace was trimmed before hashing'
[[ $(identity_for 'ID_WWN=serial ') != "$(identity_for 'ID_WWN=serial')" ]] || fail 'trailing whitespace was trimmed before hashing'
unsafe_digest=$(identity_for 'ID_WWN=another/unsafe/id')
[[ $(identity_for "ID_WWN=$unsafe_digest") != "$unsafe_digest" ]] || fail 'raw value in sha256 namespace was not hashed again'

expect_status 1 identity_for $'ID_WWN=   \nID_SERIAL=\t'
expect_status 1 identity_for ''
expect_status 1 identity_for 'ID_MODEL=missing-stable-property'
identity_property='ID_WWN=serial-42'
identity_udev_status=7
identity_hash_status=0
expect_status 1 rootpxe_disk_stable_identity /dev/mockdisk
identity_property='ID_WWN=serial with spaces'
identity_udev_status=0
identity_hash_status=7
expect_status 1 rootpxe_disk_stable_identity /dev/mockdisk

# Re-enumeration and NVMe permit checks must compare the normalized identity,
# never a raw udev value or a device path.
expected=$(identity_for 'ID_WWN=nvme serial/with slash')
rootpxe_disk_permit_granted=yes
rootpxe_disk_permit_target_id="$expected"
rootpxe_disk_permit_operation=nvme_format+deploy_write
rootpxe_nvme_permit_matches "$expected" || fail 'normalized target ID did not match permit binding'
! rootpxe_nvme_permit_matches 'nvme serial/with slash' || fail 'raw target ID bypassed normalized permit binding'

PXEOS_NVME_REENUM_DEVICE=/dev/mocknvme
PXEOS_NVME_REENUM_TIMEOUT_SEC=0
blockdev() { [[ $1 == --getss ]] && { printf '512\n'; return 0; }; return 1; }
sleep() { :; }
identity_property='ID_WWN=nvme serial/with slash'
identity_udev_status=0
identity_hash_status=0
rootpxe_nvme_wait_for_reenumeration "$expected" 512 || fail 'same normalized ID was not re-identified after NVMe re-enumeration'
[[ ${rootpxe_nvme_reformatted_disk:-} == /dev/mocknvme ]] || fail 're-enumeration selected unexpected disk path'
identity_property='ID_WWN=other serial/with slash'
unset rootpxe_nvme_reformatted_disk
expect_status 1 rootpxe_nvme_wait_for_reenumeration "$expected" 512

echo 'PASS: disk IDs preserve valid values and hash incompatible values before strict permit binding'
)
# ===== 原脚本结束：tests/pxeos_disk_identity_regression.sh =====

# ===== 原脚本：tests/pxeos_disk_permit_regression.sh =====
(
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
awk '/^rootpxe_console_message\(\)/ { copy = 1 } /^# Appends dots/ { exit } copy' "$funcs" >"$tmp/console.sh"
awk '/^dots\(\)/ { copy = 1 } /^# Enables write caching/ { exit } copy' "$funcs" >"$tmp/dots.sh"
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
    local permit_response="$1" status_response="$2" target_id="${3:-disk-serial-1}"
    local request_log="$tmp/request.log"
    taskid=7 task_token='test-token-0123456789' mac='00:0c:29:ae:cc:4f'
    pxeapi='https://rootpxe.invalid/api/'
    curl() {
        case " $* " in
            *disk-permit*) printf '%s\n' "$*" >>"$request_log"; [[ $permit_response == __CURL_TRANSPORT_FAILURE__ ]] && return 7; printf '%s' "$permit_response" ;;
            *task-status*) [[ $status_response == __CURL_TRANSPORT_FAILURE__ ]] && return 7; printf '%s' "$status_response" ;;
            *) return 1 ;;
        esac
    }
    sleep() { :; }
    rootpxe_require_task_context() { return 0; }
    . "$tmp/console.sh"
    . "$tmp/permit.sh"
    rootpxe_request_disk_permit_for_target "$target_id" 'deploy_write'
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
hashed_target='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
hashed_success=$'{"granted":true,"targetId":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","operation":"deploy_write"}\n200'
expect_status 0 run_request "$hashed_success" "$running" "$hashed_target"
grep -Fq -- "targetId=$hashed_target" "$tmp/request.log" || fail 'hashed target ID was not sent in the permit request'
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
    . "$tmp/console.sh"
    . "$tmp/dots.sh"
    . "$tmp/permit.sh"
    dots 'Waiting for disk permit'
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
grep -Fqx 'report:Task or disk binding was rejected. Confirm the task status. (HTTP 403, DISK_PERMIT_TASK_REJECTED):PXEOS_DISK_PERMIT_DENIED' "$tmp/attention.out" || fail 'permit denial report contract changed'
grep -Fq '[ERROR] Disk permission denied (HTTP 403).' "$tmp/attention.out" || fail 'HTTP diagnosis missing'
! grep -Eq '\[INFO\].*\[ERROR\]' "$tmp/attention.out" || fail 'unfinished disk-permit progress was not terminated before ERROR'
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
# completed attention wait (20) must stop before image work, hostname
# customization, or the resume post-deploy script. The snippets never receive a grant and therefore do
# not write /tmp state, mount storage, or touch a disk.
awk '/^capture_target_id=/ { armed = 1 } armed && /^while :; do/ { copy = 1 } copy { print } copy && /^done$/ { getline; print; exit }' "$upload" >"$tmp/upload-gate.sh"
awk '/^rootpxe_plan_deploy_disk_operation/ { armed = 1 } armed && /^while :; do/ { copy = 1 } copy { print } copy && /^done$/ { getline; print; exit }' "$download" >"$tmp/download-gate.sh"
awk '/^if \[\[ \$\{resumeStage:-\} == customizing_hostname \|\| \$\{resumeStage:-\} == post_deploy_script \]\]/ { copy = 1 } /^if \[\[ \$\{imgType:-\}/ { exit } copy' "$download" >"$tmp/resume-gate.sh"
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
        rootpxe_run_pre_deploy_script() { printf 'UNEXPECTED:pre-deploy\n'; return 0; }
        rootpxe_run_post_deploy_script() { printf 'UNEXPECTED:post-deploy\n'; return 0; }
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
)
# ===== 原脚本结束：tests/pxeos_disk_permit_regression.sh =====
