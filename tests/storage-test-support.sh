#!/usr/bin/env bash
# Isolated storage fixtures: real JSON/context/controller functions, ordinary
# private files, and an explicit native-process boundary. Never a NAS mount.
storage_test_load() {
    local library="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
    . "$library/storage-io.sh"
    storage_test_install_native
}

storage_test_install_native() {
    [[ -n ${tmp:-} && -d $tmp && ! -L $tmp ]] || return 1
    rootpxe_storage_helper="$tmp/storage-native-fixture"
    cat >"$rootpxe_storage_helper" <<'NATIVE'
#!/usr/bin/env bash
case ${1:-} in
    --capabilities) printf '%s\n' '{"version":1,"helper":true,"numericIdentity":true,"durablePublish":true}' ;;
    --resolve) jq -c '{numericAddress:.server,mountServer:.server,port:(if .protocol=="smb" then 445 else 2049 end)}' <&3 ;;
    --mount-nfs) printf '%s\n' '{"event":"mount","mounted":true,"errno":0}' >&6 ;;
    --context-fd)
        # The real native process owns only its declared channel descriptors.
        # Drop inherited controller FIFO anchors so request EOF can join it.
        for descriptor in {7..254}; do exec {descriptor}>&-; done
        connection=$(jq -c '{protocol:.protocol,configuredVersion:(if .protocol=="nfs" then .nfsVersion else .smbVersion end),actualVersion:(if .protocol=="nfs" then "4.1" else "3.1.1" end)}' <&3) || exit 65
        printf '{"event":"connection-info","connection":%s,"node":{"fileId":"1"}}\n' "$connection" >&6
        # Only the connection/preflight lifetime is provided. A request for
        # real data or a mutation is an unexpected fixture operation.
        while IFS= read -r request <&4; do exit 64; done
        ;;
    *) exit 64 ;;
esac
NATIVE
    chmod 700 "$rootpxe_storage_helper"
    printf '%s\n' 11111111-1111-1111-1111-111111111111 >"$tmp/storage-boot-id"
}

# Redirect only this controller's private workspace allocation. All other
# mktemp calls (including Cloud-init owner/mode contracts) remain unchanged.
mktemp() {
    if [[ $# == 2 && $1 == -d && $2 == /tmp/rootpxe-storage.XXXXXX ]]; then
        command mktemp -d "${tmp:?}/storage-context.XXXXXX"
    else command mktemp "$@"; fi
}

storage_test_reset_context() {
    if [[ -n ${rootpxe_storage_workspace:-} ]]; then
        [[ $rootpxe_storage_workspace == "$tmp/storage-context."* && -d $rootpxe_storage_workspace && ! -L $rootpxe_storage_workspace ]] || return 1
        rm -rf -- "$rootpxe_storage_workspace" || return 1
    fi
    unset rootpxe_storage_workspace rootpxe_storage_nonce rootpxe_storage_worker_nonce rootpxe_storage_stage rootpxe_storage_lock
}

storage_test_context_json() {
    jq -c '
      .taskId //= 42 | .type //= "capture" | .pxeType //= (if .type=="capture" then "up" else "down" end) |
      .executionToken //= "11111111111111111111111111111111" | .progressAttempt //= 1 |
      .img //= "images/fixture" | .imgType //= "mps" | .imgPartitionType //= "all" | .osid //= 9 | .imgFormat //= 5 |
      .deploymentIdentityPolicy //= {version:1,systemIdentity:{sysprep:false},cloudInit:false} |
      . as $r | (.protocol // (if (.storage|type)=="object" then .storage.protocol else "" end)) as $p |
      .storageAccess //= {version:1,protocol:$p,
        server:(if $p=="smb" then ($r.storageip // "") else ($r.storage.server? // $r.storageServer // $r.storage_server // $r.storageip // "") end),
        exportPath:(if $p=="smb" then ($r.exportPath // "") else ($r.storage.export? // $r.storageExport // $r.storage_export // $r.exportPath // "") end),
        imagePath:$r.img,nfsUid:1001,nfsGid:1002,nfsVersion:"auto",smbVersion:"auto",
        execution:{domainId:"11111111111111111111111111111111",taskType:$r.type,taskId:($r.taskId|tostring),executionAttempt:$r.progressAttempt,
          nonce:"22222222222222222222222222222222",targetKey:"3333333333333333333333333333333333333333333333333333333333333333",
          configRevision:"4444444444444444444444444444444444444444444444444444444444444444"}}' <<<"$1"
}

storage_test_apply_json_checkin() {
    local document
    document=$(storage_test_context_json "$1") || return 1
    storage_test_reset_context || return 1
    rootpxe_apply_json_checkin "$document"
}

storage_test_patch_parser() {
    sed -i "s|/proc/sys/kernel/random/boot_id|$tmp/storage-boot-id|g" "$1"
}

# Pipeline regressions exercise the real producer/compressor/wait code while
# replacing only remote bytes with confined ordinary-file reads and writes.
# Actual workspace/attempt validation is covered by controller/helper tests.
storage_test_pipeline_boundaries() {
    rootpxe_storage_write_payload() {
        [[ $1 == "${tmp:?}/"* && $1 != *'/../'* ]] || return 1
        if [[ $2 == 0 ]]; then cat >"$1"; else split -a 3 -d -b "$2" - "$1."; fi
    }
    rootpxe_storage_read_files() {
        local file
        for file in "$@"; do [[ $file == "${tmp:?}/"* && -f $file && ! -L $file ]] || return 1; done
        cat -- "$@"
    }
}
