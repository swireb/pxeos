#!/bin/bash
# 受控回归：验证 capture/restore/完成回调的失败不能被 shell 流水线掩盖。
# 所有外部命令均由临时 PATH mock 提供；绝不访问真实磁盘或网络。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
funcs="$overlay/usr/share/pxeos/lib/funcs.sh"
imgcomplete="$overlay/bin/pxeos.imgcomplete"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (got=$1 want=$2)"; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
count_file="${MOCK_CURL_COUNT:?}"
count=0
[ -f "$count_file" ] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"
if [ "$count" -eq 1 ]; then
    printf '%s\n' 'transient finish error' >&2
    exit 7
fi
printf '%s\n' '{"success":true}'
EOF
cat > "$tmp/bin/dmidecode" <<'EOF'
#!/bin/sh
printf '%s\n' '00000000-0000-0000-0000-000000000000'
EOF
cat > "$tmp/bin/usleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/dmidecode" "$tmp/bin/usleep"

cat > "$tmp/bash_env" <<'EOF'
rootpxe_require_task_context() { return 0; }
rootpxe_stage() { return 0; }
rootpxe_finalize_capture() { return 0; }
rootpxe_build_original_schema() { return 0; }
rootpxe_clear_capture_marker() { : > "${MOCK_MARKER_CLEARED:?}"; }
rootpxe_cleanup_task_json() { : > "${MOCK_JSON_CLEARED:?}"; }
dots() { :; }
debugPause() { :; }
handleError() { printf 'HANDLE_ERROR:%s\n' "$*" >&2; exit 91; }
EOF

# 红测：在 bash -e 的运行器中，第一次 curl 临时失败必须仍可进入第二次重试。
set +e
PATH="$tmp/bin:$PATH" BASH_ENV="$tmp/bash_env" MOCK_CURL_COUNT="$tmp/curl-count" \
    MOCK_MARKER_CLEARED="$tmp/marker-cleared" MOCK_JSON_CLEARED="$tmp/json-cleared" \
    type=down taskid=1 task_token=secret mac=001122334455 web='http://mock/' \
    bash -e "$imgcomplete" >"$tmp/imgcomplete.out" 2>"$tmp/imgcomplete.err"
imgcomplete_rc=$?
set -e
assert_eq "$imgcomplete_rc" 0 '完成回调临时失败后应重试并成功'
assert_eq "$(cat "$tmp/curl-count")" 2 '完成回调应执行两次 curl'
[[ -f "$tmp/marker-cleared" && -f "$tmp/json-cleared" ]] || fail '成功后必须执行安全清理'
pass 'finish retry survives bash errexit'

# capture 的压缩器失败时，后台 writer 的 wait 必须返回失败，不能被 split 的成功掩盖。
cat > "$tmp/bin/nproc" <<'EOF'
#!/bin/sh
printf '%s\n' 2
EOF
cat > "$tmp/bin/pigz" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 7
EOF
cat > "$tmp/bin/split" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 0
EOF
chmod +x "$tmp/bin/nproc" "$tmp/bin/pigz" "$tmp/bin/split"

sed 's|^\. /usr/share/pxeos/lib/partition-funcs.sh$|:|' "$funcs" > "$tmp/funcs.sh"
set +u
PATH="$tmp/bin:$PATH"
source "$tmp/funcs.sh" 2>/dev/null
set -u
imgFormat=2
PIGZ_COMP=-6
writer_pids=()
fifo="$tmp/capture.fifo"
uploadFormat "$fifo" "$tmp/image"
printf 'payload' > "$fifo"
set +e
rootpxe_wait_for_writer "$rootpxe_last_writer_pid"
writer_rc=$?
set -e
[[ $writer_rc -ne 0 ]] || fail 'capture writer 的压缩失败不能被 split 成功掩盖'
pass 'capture writer pipeline failure is observable'

# savePartition 必须在移动产物、进入下一分区前同步等待 writer；其失败会进入
# RootPXE attention，而不是落到最终 imgcomplete 成功回调。
cat > "$tmp/bin/partclone.extfs" <<'EOF'
#!/bin/sh
fifo=''
previous=''
for arg in "$@"; do
    [ "$previous" = '-O' ] && fifo="$arg"
    previous="$arg"
done
printf 'payload' > "$fifo"
exit 0
EOF
chmod +x "$tmp/bin/partclone.extfs"
export MOCK_ERROR_FILE="$tmp/capture-error"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 91; }
    getPartitionNumber() { part_number=1; }
    fsTypeSetting() { fstype=extfs; }
    getPartType() { parttype=0x83; }
    debugPause() { :; }
    imgPartitionType=all
    storage=mock
    img=image
    imgFormat=2
    PIGZ_COMP=-6
    writer_pids=()
    savePartition /dev/mockp1 1 "$tmp/capture-image"
) 
save_rc=$?
set -e
assert_eq "$save_rc" 91 'savePartition 必须将 writer 失败升级为任务失败'
grep -Fq 'PXEOS_STAGE=capture CODE=CAPTURE_PIPELINE_FAILED' "$tmp/capture-error" || fail 'capture writer 失败必须携带稳定 stage/code'
pass 'savePartition blocks capture success on writer failure'

# restore 中 decoder 非零、partclone 恰好返回 0 时，pipefail 仍必须阻止写盘流程继续。
cat > "$tmp/bin/zstdmt" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 9
EOF
cat > "$tmp/bin/partclone.restore" <<'EOF'
#!/bin/sh
cat >/dev/null
exit 0
EOF
chmod +x "$tmp/bin/zstdmt" "$tmp/bin/partclone.restore"
printf 'image' > "$tmp/restore-image"
rm -f /tmp/pigz1
export MOCK_ERROR_FILE="$tmp/restore-error"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 92; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/restore-image" /dev/mockp1 no
) 
restore_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$restore_rc" 92 'restore decoder 失败必须升级为任务失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_PIPELINE_FAILED' "$tmp/restore-error" || fail 'restore 失败必须携带稳定 stage/code'
pass 'restore decoder failure is not masked by partclone success'

# split 格式传入的是 img* glob；恢复时必须按 shell glob 顺序读取全部普通文件，
# 不能把星号当作字面路径，也不能接受无匹配或目录。
mkdir -p "$tmp/split"
printf 'a' > "$tmp/split/d1p1.img.000"
printf 'b' > "$tmp/split/d1p1.img.001"
printf 'c' > "$tmp/split/d1p1.img.010"
cat > "$tmp/bin/cat" <<'EOF'
#!/bin/sh
: "${MOCK_CAT_ARGS:?}"
for source_file in "$@"; do
    printf '%s\n' "$source_file" >> "$MOCK_CAT_ARGS"
    printf '%s\n' payload
done
EOF
cat > "$tmp/bin/zstdmt" <<'EOF'
#!/bin/sh
while IFS= read -r _line; do :; done
exit 0
EOF
cat > "$tmp/bin/partclone.restore" <<'EOF'
#!/bin/sh
while IFS= read -r _line; do :; done
exit 0
EOF
chmod +x "$tmp/bin/cat" "$tmp/bin/zstdmt" "$tmp/bin/partclone.restore"
export MOCK_CAT_ARGS="$tmp/split-cat-args"
rm -f /tmp/pigz1
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    : > "$MOCK_CAT_ARGS"
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 94; }
    cat() {
        local source_file
        for source_file in "$@"; do
            [[ $source_file == -- ]] && continue
            printf '%s\n' "$source_file" >> "$MOCK_CAT_ARGS"
            printf '%s\n' payload
        done
    }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/split/d1p1.img*" /dev/mockp1 no
)
split_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$split_rc" 0 'split 镜像 glob 应按顺序恢复'
expected_split_args="$(printf '%s\n' "$tmp/split/d1p1.img.000" "$tmp/split/d1p1.img.001" "$tmp/split/d1p1.img.010")"
actual_split_args="$(<"$MOCK_CAT_ARGS")"
assert_eq "$actual_split_args" "$expected_split_args" 'split 镜像必须保持 shell glob 分片顺序'
pass 'split image glob is expanded safely and in order'

export MOCK_ERROR_FILE="$tmp/split-no-match-error"
rm -f /tmp/pigz1
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 95; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/split/missing*" /dev/mockp1 no
)
split_missing_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$split_missing_rc" 95 '无匹配 split glob 必须在写盘前失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_SOURCE_UNAVAILABLE' "$tmp/split-no-match-error" || fail '无匹配 split glob 必须使用稳定错误码'
pass 'split image glob rejects no-match safely'

mkdir -p "$tmp/split/not-an-image.img.000"
export MOCK_ERROR_FILE="$tmp/split-directory-error"
rm -f /tmp/pigz1
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 96; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    writeImage "$tmp/split/not-an-image.img*" /dev/mockp1 no
)
split_directory_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$split_directory_rc" 96 'split glob 命中目录必须在写盘前失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_SOURCE_UNAVAILABLE' "$tmp/split-directory-error" || fail 'split glob 目录必须使用稳定错误码'
pass 'split image glob rejects directories safely'

upload_script="$(<"$overlay/bin/pxeos.upload")"
[[ $upload_script != *'mkfifo /tmp/pigz1'* ]] || fail '原始磁盘 capture 不得忽略独立 FIFO 建立失败'
pass 'raw capture delegates FIFO creation to checked uploadFormat'

# 镜像文件读取进程在后台失败也必须被 wait；不能因为下游刚好返回 0 而成功。
cat > "$tmp/bin/cat" <<'EOF'
#!/bin/sh
exit 11
EOF
cat > "$tmp/bin/zstdmt" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/cat" "$tmp/bin/zstdmt"
rm -f /tmp/pigz1
export MOCK_ERROR_FILE="$tmp/restore-source-error"
set +e
(
    source "$tmp/funcs.sh" 2>/dev/null
    handleError() { printf '%s\n' "$1" > "${MOCK_ERROR_FILE:?}"; exit 93; }
    imgFormat=5
    imgLegacy=''
    storage=mock
    img=image
    cat() { return 11; }
    writeImage "$tmp/restore-image" /dev/mockp1 no
)
restore_source_rc=$?
set -e
rm -f /tmp/pigz1
assert_eq "$restore_source_rc" 93 'restore 后台镜像读取失败必须升级为任务失败'
grep -Fq 'PXEOS_STAGE=restore CODE=RESTORE_SOURCE_FAILED' "$tmp/restore-source-error" || fail 'restore source 失败必须携带稳定 stage/code'
pass 'restore source failure is not masked by downstream success'

printf 'PASS: PXEOS pipeline regression\n'
