#!/bin/bash
# PXEOS 离线安装器。这里绝不执行目标二进制、用户正文或目标 systemd。
rootpxe_startup_templates="$(dirname "${BASH_SOURCE[0]}")/linux-startup-templates"
rootpxe_startup_stat() { stat -c '%u:%g:%a:%h' -- "$1"; }
rootpxe_startup_is_root() { [[ $EUID == 0 ]]; }
rootpxe_startup_executable() { [[ -x $1 ]]; }
rootpxe_startup_fail() { rootpxe_startup_error="$1"; return 1; }
rootpxe_startup_hash() {
    local value
    value=$(sha256sum -- "$1" 2>/dev/null) || return 1
    printf '%s\n' "${value%%[[:space:]]*}"
}
rootpxe_startup_metadata_safe() {
    local path="$1" kind="$2" exact="${3:-}" info uid gid mode links
    [[ ! -L $path ]] || return 1
    case $kind in directory) [[ -d $path ]];; file) [[ -f $path ]];; *) return 1;; esac || return 1
    info=$(rootpxe_startup_stat "$path") || return 1
    IFS=: read -r uid gid mode links <<<"$info"
    [[ $uid == 0 && $gid == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    [[ -z $exact || $mode == "$exact" ]] || return 1
    [[ $kind != file || $links == 1 ]]
}

# 按目标根解析每一个组件；绝对链接重新从目标根开始，最多40次链接。
# 不使用宿主 readlink -f 解析镜像路径，也不允许 .. 越过目标根。
rootpxe_startup_resolve_target() {
    local root="$1" requested="$2" kind="$3" pending component cursor link info count=0
    local -a resolved=()
    [[ $requested == /* && -d $root && ! -L $root ]] || return 1
    rootpxe_startup_metadata_safe "$root" directory || return 1
    pending="${requested#/}"
    while [[ -n $pending ]]; do
        component="${pending%%/*}"
        if [[ $pending == */* ]]; then pending="${pending#*/}"; else pending=""; fi
        case $component in
            ''|.) continue;;
            ..) (( ${#resolved[@]} > 0 )) || return 1; unset 'resolved[${#resolved[@]}-1]'; continue;;
        esac
        [[ $component != *$'\n'* && $component != *$'\r'* ]] || return 1
        cursor="$root"
        for link in "${resolved[@]}"; do cursor="$cursor/$link"; done
        cursor="$cursor/$component"
        if [[ -L $cursor ]]; then
            info=$(rootpxe_startup_stat "$cursor") || return 1
            [[ $info == 0:0:* ]] || return 1
            count=$((count + 1)); (( count <= 40 )) || return 1
            link=$(readlink -- "$cursor") || return 1
            [[ -n $link && $link != *$'\n'* && $link != *$'\r'* ]] || return 1
            if [[ $link == /* ]]; then resolved=(); link="${link#/}"; fi
            pending="$link${pending:+/$pending}"
        else
            if [[ -n $pending ]]; then rootpxe_startup_metadata_safe "$cursor" directory || return 1
            else rootpxe_startup_metadata_safe "$cursor" "$kind" || return 1; fi
            resolved+=("$component")
        fi
    done
    cursor="$root"
    for component in "${resolved[@]}"; do cursor="$cursor/$component"; done
    rootpxe_startup_metadata_safe "$cursor" "$kind" || return 1
    printf '%s\n' "$cursor"
}

rootpxe_startup_safe_write_directory() {
    local root="$1" relative="$2" create="${3:-no}" cursor component
    cursor="$root"
    local -a components
    rootpxe_startup_metadata_safe "$root" directory || return 1
    IFS=/ read -r -a components <<<"${relative#/}"
    for component in "${components[@]}"; do
        [[ -n $component && $component != . && $component != .. ]] || return 1
        cursor="$cursor/$component"
        if [[ ! -e $cursor && ! -L $cursor && $create == yes ]]; then
            mkdir -m 755 -- "$cursor" || return 1
            chown 0:0 -- "$cursor" || return 1
        fi
        rootpxe_startup_metadata_safe "$cursor" directory || return 1
    done
}
rootpxe_startup_check_conflicts() {
    local root="$1" path
    for path in /etc/systemd/system/rootpxe-startup.service.d /run/systemd/system/rootpxe-startup.service.d /usr/lib/systemd/system/rootpxe-startup.service.d /lib/systemd/system/rootpxe-startup.service.d; do
        # 能力目录可能 usr-merge；逐个解析父路径而不是跟随宿主根。
        local parent
        parent=$(rootpxe_startup_resolve_target "$root" "${path%/*}" directory) || continue
        [[ ! -e $parent/${path##*/} && ! -L $parent/${path##*/} ]] || return 1
    done
}
rootpxe_startup_check_capabilities() {
    local root="$1" tool resolved init
    init=$(rootpxe_startup_resolve_target "$root" /sbin/init file) || return 1
    case $init in "$root/usr/lib/systemd/systemd"|"$root/lib/systemd/systemd") ;; *) return 1;; esac
    rootpxe_startup_executable "$init" || return 1
    for tool in /bin/bash /usr/bin/systemctl /usr/bin/timeout /usr/bin/stat /usr/bin/readlink /usr/bin/env /usr/bin/head /usr/bin/mktemp /usr/bin/rm /usr/bin/date /usr/bin/sha256sum /usr/bin/journalctl /usr/bin/mv /usr/bin/chmod /usr/bin/mkdir; do
        resolved=$(rootpxe_startup_resolve_target "$root" "$tool" file) || return 1
        rootpxe_startup_executable "$resolved" || return 1
    done
    rootpxe_startup_check_conflicts "$root"
}

rootpxe_startup_owned_paths() {
    printf '%s\n' /etc/rootpxe/startup.sh /etc/rootpxe/startup-runner.sh /etc/rootpxe/startup-result.sh /etc/systemd/system/rootpxe-startup.service
}
rootpxe_startup_verify_manifest() {
    local root="$1" manifest type path mode hash extra expected count=0 seen='|' link_optional="${2:-no}"
    manifest="$root/etc/rootpxe/startup.manifest"
    rootpxe_startup_metadata_safe "$manifest" file 600 || return 1
    [[ $(wc -c <"$manifest") -le 2048 ]] || return 1
    IFS= read -r expected <"$manifest" || return 1
    [[ $expected == ROOTPXE_LINUX_STARTUP_V1 ]] || return 1
    while IFS=$'\t' read -r type path mode hash extra; do
        [[ -z $extra && $seen != *"|$path|"* ]] || return 1
        case "$type:$path:$mode" in
            F:/etc/rootpxe/startup.sh:700|F:/etc/rootpxe/startup-runner.sh:700|F:/etc/rootpxe/startup-result.sh:700|F:/etc/systemd/system/rootpxe-startup.service:644)
                [[ $hash =~ ^[0-9a-f]{64}$ ]] || return 1
                rootpxe_startup_metadata_safe "$root$path" file "$mode" || return 1
                [[ $(rootpxe_startup_hash "$root$path") == "$hash" ]] || return 1
                ;;
            L:/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service:link)
                [[ $hash == ../rootpxe-startup.service ]] || return 1
                if [[ $link_optional == yes && ! -e $root$path && ! -L $root$path ]]; then :
                else [[ -L $root$path && $(rootpxe_startup_stat "$root$path") == 0:0:* && $(rootpxe_startup_readlink "$root$path") == "$hash" ]] || return 1; fi
                ;;
            *) return 1;;
        esac
        count=$((count + 1)); seen="$seen$path|"
    done < <(tail -n +2 "$manifest")
    [[ $count -eq 5 ]]
}
rootpxe_startup_existing_state() {
    local root="$1" path manifest
    manifest="$root/etc/rootpxe/startup.manifest"
    rootpxe_startup_existing_managed=no
    if [[ -e $manifest || -L $manifest ]]; then
        rootpxe_startup_verify_manifest "$root" || return 1
        rootpxe_startup_existing_managed=yes
        return 0
    fi
    while IFS= read -r path; do [[ ! -e $root$path && ! -L $root$path ]] || return 1; done < <(rootpxe_startup_owned_paths)
    path="$root/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service"
    [[ ! -e $path && ! -L $path ]]
}

# 只使用 PXEOS 可信标签工具与镜像自带的目标策略；不运行目标 restorecon。
rootpxe_startup_target_selinux() {
    local root="$1" config mode policy line path
    config="$root/etc/selinux/config"
    rootpxe_startup_selinux_contexts=""
    [[ -e $root/etc/selinux || -L $root/etc/selinux ]] || return 0
    rootpxe_startup_safe_write_directory "$root" /etc/selinux || return 1
    rootpxe_startup_metadata_safe "$config" file || return 1
    mode=$(awk -F= '/^[[:space:]]*SELINUX=/{gsub(/[[:space:]]/,"",$2); print $2}' "$config")
    [[ $mode == disabled ]] && return 0
    [[ $mode == enforcing || $mode == permissive ]] || return 1
    policy=$(awk -F= '/^[[:space:]]*SELINUXTYPE=/{gsub(/[[:space:]]/,"",$2); print $2}' "$config")
    [[ $policy =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    path="/etc/selinux/$policy/contexts/files"
    rootpxe_startup_safe_write_directory "$root" "$path" || return 1
    rootpxe_startup_selinux_contexts="$root$path/file_contexts"
    rootpxe_startup_metadata_safe "$rootpxe_startup_selinux_contexts" file || return 1
    for line in .bin .local .local.bin .subs .subs_dist .homedirs .homedirs.bin; do
        path="$rootpxe_startup_selinux_contexts$line"
        [[ ! -e $path && ! -L $path ]] || rootpxe_startup_metadata_safe "$path" file || return 1
    done
}
rootpxe_startup_label_tools_ready() {
    command -v matchpathcon >/dev/null 2>&1 && command -v setfattr >/dev/null 2>&1 &&
        command -v getfattr >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1
}
rootpxe_startup_expected_label() {
    timeout 10 matchpathcon -n -f "$rootpxe_startup_selinux_contexts" "$1" 2>/dev/null
}
rootpxe_startup_write_label() { setfattr -h -n security.selinux -v "$2" -- "$1" 2>/dev/null; }
rootpxe_startup_read_label() { getfattr -h --only-values -n security.selinux -- "$1" 2>/dev/null | tr -d '\000'; }
rootpxe_startup_label_path() {
    local physical="$1" target="$2" label actual
    [[ -n ${rootpxe_startup_selinux_contexts:-} ]] || return 0
    label=$(rootpxe_startup_expected_label "$target") || return 1
    [[ $label =~ ^[A-Za-z0-9_]+:[A-Za-z0-9_]+:[A-Za-z0-9_]+:s[0-9]+(:[A-Za-z0-9_,.-]+)?$ ]] || return 1
    rootpxe_startup_write_label "$physical" "$label" || return 1
    actual=$(rootpxe_startup_read_label "$physical") || return 1
    [[ $actual == "$label" ]]
}
rootpxe_startup_stage_remove() {
    local stage="$1" name
    [[ $stage == */etc/rootpxe/.startup-new.* && -d $stage && ! -L $stage ]] || return 1
    for name in startup.sh startup-runner.sh startup-result.sh rootpxe-startup.service startup.manifest enable.link; do
        [[ ! -d $stage/$name ]] || return 1
        rm -f -- "$stage/$name" || return 1
    done
    rmdir -- "$stage"
}
rootpxe_startup_inode() { stat -c '%d:%i' -- "$1"; }
rootpxe_startup_move() { mv -n -- "$1" "$2"; }
rootpxe_startup_readlink() { readlink -- "$1"; }
rootpxe_startup_file_path() {
    case $1 in
        startup.sh|startup-runner.sh|startup-result.sh|startup.manifest) printf '/etc/rootpxe/%s' "$1";;
        rootpxe-startup.service) printf '/etc/systemd/system/%s' "$1";;
        *) return 1;;
    esac
}
rootpxe_startup_file_mode() { case $1 in startup.manifest) printf 600;; rootpxe-startup.service) printf 644;; *) printf 700;; esac; }
rootpxe_startup_file_description() {
    local file="$1" mode="$2" hash inode
    rootpxe_startup_metadata_safe "$file" file "$mode" || return 1
    hash=$(rootpxe_startup_hash "$file") && inode=$(rootpxe_startup_inode "$file") || return 1
    jq -cn --arg hash "$hash" --arg inode "$inode" --arg mode "$mode" '{hash:$hash,inode:$inode,mode:$mode}'
}
rootpxe_startup_file_matches() {
    local file="$1" record="$2" hash inode mode
    [[ $record != null && -n $record ]] || return 1
    IFS=$'\t' read -r hash inode mode < <(jq -r '[.hash,.inode,.mode]|@tsv' <<<"$record") || return 1
    rootpxe_startup_metadata_safe "$file" file "$mode" &&
        [[ $(rootpxe_startup_inode "$file") == "$inode" && $(rootpxe_startup_hash "$file") == "$hash" ]]
}
rootpxe_startup_link_description() {
    local file="$1" target inode info
    [[ -L $file ]] || return 1
    info=$(rootpxe_startup_stat "$file") || return 1
    [[ $info == 0:0:* ]] || return 1
    target=$(rootpxe_startup_readlink "$file") && inode=$(rootpxe_startup_inode "$file") || return 1
    [[ $target == ../rootpxe-startup.service ]] || return 1
    jq -cn --arg inode "$inode" --arg target "$target" '{inode:$inode,target:$target}'
}
rootpxe_startup_link_matches() {
    local actual record="$2"
    actual=$(rootpxe_startup_link_description "$1") || return 1
    [[ $(jq -cS . <<<"$actual") == "$(jq -cS 'del(.path)' <<<"$record")" ]]
}
rootpxe_startup_readonly_structure() {
    local root="$1" path cursor component root_device device
    rootpxe_startup_metadata_safe "$root" directory && rootpxe_startup_safe_write_directory "$root" /etc || return 1
    root_device=$(stat -c %d "$root") || return 1
    for path in /etc/rootpxe /etc/systemd /etc/systemd/system /etc/systemd/system/multi-user.target.wants; do
        cursor="$root"
        local -a components
        IFS=/ read -r -a components <<<"${path#/}"
        for component in "${components[@]}"; do
            cursor="$cursor/$component"
            [[ -e $cursor || -L $cursor ]] || break
            rootpxe_startup_metadata_safe "$cursor" directory || return 1
            device=$(stat -c %d "$cursor") || return 1
            [[ $device == "$root_device" ]] || return 1
        done
    done
}
rootpxe_startup_transaction_validate() {
    jq -e '
      def entry: type=="object" and (keys|sort)==["hash","inode","mode"] and
        (.hash|type=="string" and test("^[a-f0-9]{64}$")) and (.inode|type=="string" and test("^[0-9]+:[0-9]+$")) and (.mode|IN("600","644","700"));
      def files: type=="object" and ((keys|sort)==[] or (keys|sort)==["rootpxe-startup.service","startup-result.sh","startup-runner.sh","startup.manifest","startup.sh"]) and
        all(to_entries[]; .value|entry) and
        all(to_entries[]; (.key=="startup.manifest" and .value.mode=="600") or (.key=="rootpxe-startup.service" and .value.mode=="644") or ((.key|IN("startup.sh","startup-runner.sh","startup-result.sh")) and .value.mode=="700"));
      def link: type=="object" and (keys|sort)==["inode","target"] and .target=="../rootpxe-startup.service" and (.inode|type=="string" and test("^[0-9]+:[0-9]+$"));
      type=="object" and (keys|sort)==["action","directories","newEnable","newFiles","oldEnable","oldFiles","stage","stageId","state","version"] and
      .version==1 and (.action|IN("install","clear")) and (.state|IN("prepared","committed","restored")) and
      (.stage|type=="string" and test("^/etc/rootpxe/[.]startup-new[.][A-Za-z0-9]{6}$")) and
      (.stageId|type=="string" and test("^[0-9]+:[0-9]+$")) and (.oldFiles|files) and (.newFiles|files) and
      (if (.oldFiles|length)==0 then .oldEnable==null else .oldEnable|link end) and
      (if .action=="install" then (.newFiles|length)==5 and (.newEnable|type=="object") and
        ((.newEnable|del(.path))|link) and
        (.newEnable.path|type=="string" and test("^/etc/systemd/system/multi-user[.]target[.]wants/[.]rootpxe-startup-link[.][A-Za-z0-9]{6}$"))
       else (.newFiles|length)==0 and .newEnable==null and (.oldFiles|length)==5 end) and
      (.directories|type=="array" and length<=4 and (map(.path)|unique|length)==length and
        all(.[]; type=="object" and (keys|sort)==["inode","mode","path"] and
          (.inode|type=="string" and test("^[0-9]+:[0-9]+$")) and
          ((.path=="/etc/rootpxe" and .mode=="700") or ((.path|IN("/etc/systemd","/etc/systemd/system","/etc/systemd/system/multi-user.target.wants")) and .mode=="755"))))
    ' >/dev/null 2>&1 <<<"$1"
}
rootpxe_startup_transaction_write() {
    local root="$1" data="$2" temp tx
    tx="$root/etc/rootpxe/startup.transaction"
    rootpxe_startup_transaction_validate "$data" || return 1
    [[ ! -e $tx && ! -L $tx ]] || rootpxe_startup_metadata_safe "$tx" file 600 || return 1
    temp=$(mktemp "$root/etc/rootpxe/.startup-transaction.XXXXXX") || return 1
    printf '%s\n' "$data" >"$temp" && chmod 600 "$temp" && chown 0:0 "$temp" &&
        rootpxe_startup_label_path "$temp" /etc/rootpxe/startup.transaction &&
        mv -f -- "$temp" "$tx" || { rm -f -- "$temp"; return 1; }
}
rootpxe_startup_transaction_target_matches() {
    local root="$1" data="$2" side="$3" name path record enable
    for name in startup.sh startup-runner.sh startup-result.sh rootpxe-startup.service startup.manifest; do
        path=$(rootpxe_startup_file_path "$name") || return 1
        record=$(jq -c --arg side "$side" --arg name "$name" '.[$side+"Files"][$name]' <<<"$data") || return 1
        if [[ $record == null ]]; then [[ ! -e $root$path && ! -L $root$path ]] || return 1
        else rootpxe_startup_file_matches "$root$path" "$record" || return 1; fi
    done
    enable=$(jq -c --arg side "$side" '.[$side+"Enable"]' <<<"$data") || return 1
    path="$root/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service"
    if [[ $enable == null ]]; then [[ ! -e $path && ! -L $path ]]
    else rootpxe_startup_link_matches "$path" "$enable" && rootpxe_startup_verify_manifest "$root"; fi
}
rootpxe_startup_transaction_stage_safe() {
    local root="$1" data="$2" stage node name record side identity
    stage="$root$(jq -r '.stage' <<<"$data")"
    [[ -e $stage || -L $stage ]] || return 0
    rootpxe_startup_metadata_safe "$stage" directory 700 && [[ $(rootpxe_startup_inode "$stage") == "$(jq -r '.stageId' <<<"$data")" ]] || return 1
    for node in "$stage"/* "$stage"/.[!.]* "$stage"/..?*; do
        [[ -e $node || -L $node ]] || continue
        name="${node##*/}"; side=new
        [[ $name != old.* ]] || { side=old; name="${name#old.}"; }
        if [[ $name == enable && $side == old ]]; then
            record=$(jq -c '.oldEnable' <<<"$data")
            rootpxe_startup_link_matches "$node" "$record" || return 1
        else
            rootpxe_startup_file_path "$name" >/dev/null || return 1
            record=$(jq -c --arg side "$side" --arg name "$name" '.[$side+"Files"][$name]' <<<"$data")
            rootpxe_startup_file_matches "$node" "$record" || return 1
        fi
    done
}
rootpxe_startup_transaction_cleanup() {
    local root="$1" data="$2" stage node path inode mode state side new_enable root_directory=null child
    state=$(jq -r '.state' <<<"$data"); side=new
    [[ $state != restored ]] || side=old
    rootpxe_startup_transaction_target_matches "$root" "$data" "$side" && rootpxe_startup_transaction_stage_safe "$root" "$data" || return 1
    new_enable=$(jq -c '.newEnable' <<<"$data")
    if [[ $new_enable != null ]]; then
        path="$root$(jq -r '.path' <<<"$new_enable")"
        if [[ -e $path || -L $path ]]; then rootpxe_startup_link_matches "$path" "$new_enable" && rm -- "$path" || return 1; fi
    fi
    stage="$root$(jq -r '.stage' <<<"$data")"
    if [[ -d $stage ]]; then
        for node in "$stage"/* "$stage"/.[!.]* "$stage"/..?*; do [[ ! -e $node && ! -L $node ]] || rm -- "$node" || return 1; done
        rmdir -- "$stage" || return 1
    fi
    # 先清理外围新目录；中途失败始终保留tx，已消失目录可作为完成步骤重试。
    if [[ $state == restored ]]; then
        while IFS=$'\t' read -r path inode mode; do
            if [[ $path == /etc/rootpxe ]]; then
                root_directory=$(jq -c '.directories[]|select(.path=="/etc/rootpxe")' <<<"$data")
                continue
            fi
            [[ -e $root$path || -L $root$path ]] || continue
            rootpxe_startup_metadata_safe "$root$path" directory "$mode" &&
                [[ $(rootpxe_startup_inode "$root$path") == "$inode" ]] || return 1
            rmdir -- "$root$path" || return 1
        done < <(jq -r '.directories|reverse[]|[.path,.inode,.mode]|@tsv' <<<"$data")
    fi
    if [[ $root_directory != null ]]; then
        inode=$(jq -r '.inode' <<<"$root_directory")
        rootpxe_startup_metadata_safe "$root/etc/rootpxe" directory 700 &&
            [[ $(rootpxe_startup_inode "$root/etc/rootpxe") == "$inode" ]] || return 1
        for child in "$root/etc/rootpxe"/* "$root/etc/rootpxe"/.[!.]* "$root/etc/rootpxe"/..?*; do
            [[ ! -e $child && ! -L $child || $child == "$root/etc/rootpxe/startup.transaction" ]] || return 1
        done
    fi
    rm -- "$root/etc/rootpxe/startup.transaction" || return 1
    if [[ $root_directory != null ]] && ! rmdir -- "$root/etc/rootpxe"; then
        # 最后rm/rmdir之间的进程中断只可能留下无hook空目录，不宣称断电原子。
        rootpxe_startup_metadata_safe "$root/etc/rootpxe" directory 700 &&
            [[ $(rootpxe_startup_inode "$root/etc/rootpxe") == "$inode" ]] &&
            rootpxe_startup_transaction_write "$root" "$data" || return 1
        return 1
    fi
}
rootpxe_startup_transaction_restore() {
    local root="$1" data="$2" stage name path old new record target old_enable new_enable restored
    stage="$root$(jq -r '.stage' <<<"$data")"
    rootpxe_startup_metadata_safe "$stage" directory 700 && [[ $(rootpxe_startup_inode "$stage") == "$(jq -r '.stageId' <<<"$data")" ]] &&
        rootpxe_startup_transaction_stage_safe "$root" "$data" || return 1
    target="$root/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service"
    old_enable=$(jq -c '.oldEnable' <<<"$data"); new_enable=$(jq -c '.newEnable' <<<"$data")
    if [[ -e $target || -L $target ]]; then
        if rootpxe_startup_link_matches "$target" "$new_enable"; then rm -- "$target" || return 1
        elif ! rootpxe_startup_link_matches "$target" "$old_enable"; then return 1; fi
    fi
    for name in startup.sh startup-runner.sh startup-result.sh rootpxe-startup.service startup.manifest; do
        path=$(rootpxe_startup_file_path "$name")
        old=$(jq -c --arg name "$name" '.oldFiles[$name]' <<<"$data"); new=$(jq -c --arg name "$name" '.newFiles[$name]' <<<"$data")
        if [[ -e $root$path || -L $root$path ]]; then
            if rootpxe_startup_file_matches "$root$path" "$new"; then rm -- "$root$path" || return 1
            elif ! rootpxe_startup_file_matches "$root$path" "$old"; then return 1; fi
        fi
        if [[ $old != null ]]; then
            if [[ -e $stage/old.$name || -L $stage/old.$name ]]; then
                rootpxe_startup_file_matches "$stage/old.$name" "$old" &&
                    [[ ! -e $root$path && ! -L $root$path ]] &&
                    rootpxe_startup_move "$stage/old.$name" "$root$path" &&
                    rootpxe_startup_file_matches "$root$path" "$old" || return 1
            else rootpxe_startup_file_matches "$root$path" "$old" || return 1; fi
        fi
    done
    if [[ $old_enable != null ]]; then
        rootpxe_startup_verify_manifest "$root" yes || return 1
        if [[ ! -e $target && ! -L $target ]]; then
            rootpxe_startup_link_matches "$stage/old.enable" "$old_enable" &&
                rootpxe_startup_move "$stage/old.enable" "$target" || return 1
        fi
        rootpxe_startup_verify_manifest "$root" || return 1
    fi
    restored=$(jq -c '.state="restored"' <<<"$data")
    rootpxe_startup_transaction_write "$root" "$restored" &&
        rootpxe_startup_transaction_cleanup "$root" "$restored"
}
rootpxe_startup_transaction_recover() {
    local root="$1" tx data state stage
    local rootpxe_startup_selinux_contexts=""
    tx="$root/etc/rootpxe/startup.transaction"
    [[ -e $tx || -L $tx ]] || return 0
    rootpxe_startup_metadata_safe "$root/etc/rootpxe" directory 700 &&
        rootpxe_startup_metadata_safe "$tx" file 600 && [[ $(wc -c <"$tx") -le 16384 ]] || return 1
    data=$(cat "$tx") && rootpxe_startup_transaction_validate "$data" || return 1
    state=$(jq -r '.state' <<<"$data")
    if [[ $state == prepared ]]; then rootpxe_startup_transaction_restore "$root" "$data"
    else rootpxe_startup_transaction_cleanup "$root" "$data"; fi
}
rootpxe_startup_prepare_directories() {
    local root="$1" path mode inode record cursor component
    rootpxe_startup_created_directories='[]'
    for path in /etc/rootpxe /etc/systemd /etc/systemd/system /etc/systemd/system/multi-user.target.wants; do
        if [[ ! -e $root$path && ! -L $root$path ]]; then
            mode=755; [[ $path != /etc/rootpxe ]] || mode=700
            mkdir -m "$mode" -- "$root$path" && chown 0:0 -- "$root$path" || return 1
            inode=$(rootpxe_startup_inode "$root$path") || return 1
            record=$(jq -cn --arg path "$path" --arg inode "$inode" --arg mode "$mode" '{path:$path,inode:$inode,mode:$mode}')
            rootpxe_startup_created_directories=$(jq -c --argjson item "$record" '.+[$item]' <<<"$rootpxe_startup_created_directories") || return 1
            rootpxe_startup_metadata_safe "$root$path" directory "$mode" && rootpxe_startup_label_path "$root$path" "$path" || return 1
        fi
    done
    rootpxe_startup_metadata_safe "$root/etc/rootpxe" directory 700
}
rootpxe_startup_remove_created_directories() {
    local root="$1" data="$2" path inode mode result=0
    while IFS=$'\t' read -r path inode mode; do
        rootpxe_startup_metadata_safe "$root$path" directory "$mode" &&
            [[ $(rootpxe_startup_inode "$root$path") == "$inode" ]] &&
            rmdir -- "$root$path" || result=1
    done < <(jq -r 'reverse[]|[.path,.inode,.mode]|@tsv' <<<"$data")
    return "$result"
}
rootpxe_startup_install_at_root() {
    local root="$1" script="$2" hash="$3" stage="" path name mode expected current size result=0 action=install
    local old_files='{}' new_files='{}' old_enable=null new_enable=null record txdata committed enable_temp="" stage_id created='[]'
    # 恢复原inode/xattr不借用继承或上一挂载根的policy；非空预检随后选择本根策略。
    local rootpxe_startup_selinux_contexts=""
    rootpxe_startup_is_root || return 1
    rootpxe_startup_error=""
    rootpxe_startup_readonly_structure "$root" || { rootpxe_startup_fail startup_path_unsafe; return 1; }
    rootpxe_startup_transaction_recover "$root" || { rootpxe_startup_fail startup_transaction_unproven; return 1; }
    rootpxe_startup_check_conflicts "$root" && rootpxe_startup_existing_state "$root" || { rootpxe_startup_fail startup_ownership_conflict; return 1; }
    if [[ -z $script && -z $hash ]]; then
        [[ $rootpxe_startup_existing_managed == yes ]] || return 0
        action=clear
        rootpxe_startup_selinux_contexts=""
    else
        [[ -f $script && ! -L $script && $hash =~ ^[0-9a-f]{64}$ ]] || { rootpxe_startup_fail startup_script_invalid; return 1; }
        size=$(wc -c <"$script")
        [[ $size =~ ^[0-9]+$ && $size -gt 0 && $size -le 65536 && $(rootpxe_startup_hash "$script") == "$hash" ]] || { rootpxe_startup_fail startup_script_hash_mismatch; return 1; }
        rootpxe_startup_check_capabilities "$root" || { rootpxe_startup_fail startup_target_capability_missing; return 1; }
        for name in rootpxe-startup.service startup-runner.sh startup-result.sh; do
            [[ -f $rootpxe_startup_templates/$name && ! -L $rootpxe_startup_templates/$name ]] && rootpxe_startup_hash "$rootpxe_startup_templates/$name" >/dev/null || return 1
        done
        rootpxe_startup_target_selinux "$root" || { rootpxe_startup_fail startup_selinux_policy_invalid; return 1; }
        if [[ -n $rootpxe_startup_selinux_contexts ]]; then
            rootpxe_startup_label_tools_ready || { rootpxe_startup_fail startup_selinux_tools_missing; return 1; }
            for path in /etc/rootpxe /etc/systemd /etc/systemd/system /etc/systemd/system/multi-user.target.wants /etc/rootpxe/startup.sh /etc/rootpxe/startup-runner.sh /etc/rootpxe/startup-result.sh /etc/rootpxe/startup.manifest /etc/rootpxe/startup.transaction /etc/systemd/system/rootpxe-startup.service /etc/systemd/system/multi-user.target.wants/rootpxe-startup.service; do
                expected=$(rootpxe_startup_expected_label "$path") || return 1
                [[ $expected =~ ^[A-Za-z0-9_]+:[A-Za-z0-9_]+:[A-Za-z0-9_]+:s[0-9]+(:[A-Za-z0-9_,.-]+)?$ ]] || return 1
            done
        fi
    fi
    rootpxe_startup_prepare_directories "$root" || { rootpxe_startup_remove_created_directories "$root" "$rootpxe_startup_created_directories"; return 1; }
    created="$rootpxe_startup_created_directories"
    stage=$(mktemp -d "$root/etc/rootpxe/.startup-new.XXXXXX") || { rootpxe_startup_remove_created_directories "$root" "$created"; return 1; }
    chmod 700 "$stage" && chown 0:0 "$stage" || result=1
    stage_id=$(rootpxe_startup_inode "$stage") || result=1
    if [[ $rootpxe_startup_existing_managed == yes ]]; then
        for name in startup.sh startup-runner.sh startup-result.sh rootpxe-startup.service startup.manifest; do
            path=$(rootpxe_startup_file_path "$name"); mode=$(rootpxe_startup_file_mode "$name")
            record=$(rootpxe_startup_file_description "$root$path" "$mode") || { result=1; break; }
            old_files=$(jq -c --arg name "$name" --argjson record "$record" '.[$name]=$record' <<<"$old_files") || result=1
        done
        old_enable=$(rootpxe_startup_link_description "$root/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service") || result=1
    fi
    if [[ $result -eq 0 && $action == install ]]; then
        printf 'ROOTPXE_LINUX_STARTUP_V1\n' >"$stage/startup.manifest" || result=1
        while IFS= read -r path; do
            [[ $result -eq 0 ]] || break
            name="${path##*/}"; mode=$(rootpxe_startup_file_mode "$name")
            current="$rootpxe_startup_templates/$name"; [[ $name != startup.sh ]] || current="$script"
            expected=$(rootpxe_startup_hash "$current") || { result=1; break; }
            cp -- "$current" "$stage/$name" && chmod "$mode" "$stage/$name" && chown 0:0 "$stage/$name" &&
                rootpxe_startup_label_path "$stage/$name" "$path" &&
                [[ $(rootpxe_startup_hash "$stage/$name") == "$expected" ]] || { result=1; break; }
            printf 'F\t%s\t%s\t%s\n' "$path" "$mode" "$expected" >>"$stage/startup.manifest" || result=1
        done < <(rootpxe_startup_owned_paths)
        if [[ $result -eq 0 ]]; then
            printf 'L\t/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service\tlink\t../rootpxe-startup.service\n' >>"$stage/startup.manifest" &&
                chmod 600 "$stage/startup.manifest" && chown 0:0 "$stage/startup.manifest" &&
                rootpxe_startup_label_path "$stage/startup.manifest" /etc/rootpxe/startup.manifest || result=1
            for name in startup.sh startup-runner.sh startup-result.sh rootpxe-startup.service startup.manifest; do
                mode=$(rootpxe_startup_file_mode "$name")
                record=$(rootpxe_startup_file_description "$stage/$name" "$mode") || { result=1; break; }
                new_files=$(jq -c --arg name "$name" --argjson record "$record" '.[$name]=$record' <<<"$new_files") || result=1
            done
        fi
        if [[ $result -eq 0 ]]; then
            enable_temp=$(mktemp "$root/etc/systemd/system/multi-user.target.wants/.rootpxe-startup-link.XXXXXX") || result=1
            if [[ $result -eq 0 ]]; then
                rm -- "$enable_temp" && ln -s ../rootpxe-startup.service "$enable_temp" && chown -h 0:0 "$enable_temp" &&
                    rootpxe_startup_label_path "$enable_temp" /etc/systemd/system/multi-user.target.wants/rootpxe-startup.service || result=1
                new_enable=$(rootpxe_startup_link_description "$enable_temp") || result=1
                new_enable=$(jq -c --arg path "${enable_temp#"$root"}" '.path=$path' <<<"$new_enable") || result=1
            fi
        fi
    fi
    txdata=$(jq -cn --arg action "$action" --arg stage "${stage#"$root"}" --arg stageId "$stage_id" --argjson oldFiles "$old_files" --argjson newFiles "$new_files" --argjson oldEnable "$old_enable" --argjson newEnable "$new_enable" --argjson directories "$created" '{version:1,state:"prepared",action:$action,stage:$stage,stageId:$stageId,oldFiles:$oldFiles,newFiles:$newFiles,oldEnable:$oldEnable,newEnable:$newEnable,directories:$directories}') || result=1
    if [[ $result -ne 0 ]] || ! rootpxe_startup_transaction_write "$root" "$txdata"; then
        [[ -z $enable_temp ]] || rm -f -- "$enable_temp"
        rootpxe_startup_stage_remove "$stage"
        rootpxe_startup_remove_created_directories "$root" "$created"
        rootpxe_startup_fail startup_preparation_failed; return 1
    fi
    if [[ $old_enable != null ]]; then
        rootpxe_startup_link_matches "$root/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service" "$old_enable" &&
            rootpxe_startup_move "$root/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service" "$stage/old.enable" || result=1
    fi
    for name in startup.sh startup-runner.sh startup-result.sh rootpxe-startup.service startup.manifest; do
        [[ $result -eq 0 ]] || break
        path=$(rootpxe_startup_file_path "$name"); record=$(jq -c --arg name "$name" '.oldFiles[$name]' <<<"$txdata")
        if [[ $record != null ]]; then
            rootpxe_startup_file_matches "$root$path" "$record" &&
                rootpxe_startup_move "$root$path" "$stage/old.$name" &&
                rootpxe_startup_file_matches "$stage/old.$name" "$record" || result=1
        fi
    done
    if [[ $result -eq 0 && $action == install ]]; then
        for name in startup.sh startup-runner.sh startup-result.sh rootpxe-startup.service startup.manifest; do
            path=$(rootpxe_startup_file_path "$name"); record=$(jq -c --arg name "$name" '.newFiles[$name]' <<<"$txdata")
            [[ ! -e $root$path && ! -L $root$path ]] && rootpxe_startup_move "$stage/$name" "$root$path" &&
                rootpxe_startup_file_matches "$root$path" "$record" && rootpxe_startup_label_path "$root$path" "$path" || { result=1; break; }
        done
        if [[ $result -eq 0 ]]; then
            rootpxe_startup_verify_manifest "$root" yes &&
                rootpxe_startup_link_matches "$enable_temp" "$new_enable" &&
                rootpxe_startup_move "$enable_temp" "$root/etc/systemd/system/multi-user.target.wants/rootpxe-startup.service" &&
                rootpxe_startup_transaction_target_matches "$root" "$txdata" new || result=1
        fi
    fi
    if [[ $result -ne 0 ]]; then
        rootpxe_startup_transaction_restore "$root" "$txdata" || { rootpxe_startup_fail startup_rollback_unproven; return 1; }
        rootpxe_startup_fail startup_install_rolled_back; return 1
    fi
    committed=$(jq -c '.state="committed"' <<<"$txdata")
    if ! rootpxe_startup_transaction_write "$root" "$committed"; then
        rootpxe_startup_transaction_restore "$root" "$txdata" || { rootpxe_startup_fail startup_rollback_unproven; return 1; }
        rootpxe_startup_fail startup_commit_rolled_back; return 1
    fi
    rootpxe_startup_transaction_cleanup "$root" "$committed" || { rootpxe_startup_fail startup_committed_cleanup_pending; return 1; }
}

rootpxe_startup_device_on_disk() {
    local disk="$1" device="$2" part resolved rows name uuid lv
    rootpxe_verify_disk_permit_binding "$disk" deploy_write || return 1
    getPartitions "$disk"
    for part in ${parts:-}; do
        resolved=$(readlink -f -- "$part") || return 1
        [[ $resolved != "$device" ]] || return 0
    done
    rows=$(rootpxe_lvm_native lvs --reportformat json -o lv_path,vg_name,vg_uuid 2>/dev/null) || return 1
    rootpxe_lvm_json_jq -e '.report|type=="array" and length==1 and (.[0].lv|type=="array")' <<<"$rows" >/dev/null || return 1
    while IFS=$'\t' read -r lv name uuid; do
        [[ -n $lv && -n $name && -n $uuid ]] || return 1
        resolved=$(readlink -f -- "$lv") || continue
        [[ $resolved == "$device" ]] || continue
        rootpxe_linux_validate_vg_target_pvs "$disk" "$uuid" || return 1
        rootpxe_startup_usr_vg_name="$name"; rootpxe_startup_usr_vg_uuid="$uuid"
        rootpxe_startup_usr_vg_owned=$(rootpxe_linux_activate_vg_if_needed "$disk" "$name" "$uuid") || return 1
        return 0
    done < <(rootpxe_lvm_json_jq -r '.report[0].lv[]|[.lv_path,.vg_name,.vg_uuid]|@tsv' <<<"$rows")
    return 1
}
rootpxe_startup_mount_matches() {
    local path="$1" device="$2" mode="$3" subvol="${4:-}" options
    rootpxe_deployment_identity_mount_matches_device "$path" "$device" || return 1
    options=$(findmnt -rn --mountpoint "$path" -o OPTIONS) || return 1
    [[ ,$options, == *",$mode,"* ]] || return 1
    [[ -z $subvol || ,$options, == *",subvolid=$subvol,"* ]]
}
rootpxe_startup_mount_usr() {
    local root="$1" disk="$2" mode="$3" source target declared options rest count=0 device fs subvol="" mount_options
    rootpxe_startup_usr_owned=no; rootpxe_startup_usr_mount=""
    rootpxe_startup_usr_vg_name=""; rootpxe_startup_usr_vg_uuid=""; rootpxe_startup_usr_vg_owned=no
    [[ -e $root/etc/fstab || -L $root/etc/fstab ]] || return 0
    rootpxe_startup_metadata_safe "$root/etc/fstab" file || return 1
    while read -r source target declared options rest; do
        [[ $source != \#* && $target == /usr ]] || continue
        count=$((count + 1)); [[ $count -eq 1 ]] || return 1
        device=$(rootpxe_deployment_identity_linux_fstab_source_device "$source") || return 1
        rootpxe_startup_device_on_disk "$disk" "$device" || return 1
        fs=$(blkid -s TYPE -o value "$device" 2>/dev/null) || return 1
        [[ $fs == "$declared" ]] && rootpxe_linux_root_fstype_supported "$fs" || return 1
        if [[ $fs == btrfs ]]; then
            [[ ,$options, != *,subvol=* ]] || return 1
            for rest in ${options//,/ }; do [[ $rest != subvolid=* ]] || subvol="${rest#subvolid=}"; done
            [[ -z $subvol ]] || rootpxe_linux_btrfs_subvolid_valid "$subvol" || return 1
        fi
        rootpxe_startup_safe_write_directory "$root" /usr || return 1
        if mountpoint -q "$root/usr"; then
            rootpxe_startup_mount_matches "$root/usr" "$device" "$mode" "$subvol" || return 1
        else
            mount_options=$(rootpxe_linux_mount_options "$mode" "$fs" "$subvol") || return 1
            mount -t "$fs" -o "$mount_options" "$device" "$root/usr" || return 1
            rootpxe_startup_usr_owned=yes; rootpxe_startup_usr_mount="$root/usr"
            rootpxe_startup_mount_matches "$root/usr" "$device" "$mode" "$subvol" || return 1
        fi
    done <"$root/etc/fstab"
    return 0
}
rootpxe_startup_cleanup_usr() {
    local result=0
    if [[ ${rootpxe_startup_usr_owned:-no} == yes ]]; then umount "$rootpxe_startup_usr_mount" || result=1; fi
    if [[ $result -eq 0 ]]; then
        rootpxe_linux_cleanup_selected_vg "${rootpxe_startup_usr_vg_name:-}" "${rootpxe_startup_usr_vg_uuid:-}" "${rootpxe_startup_usr_vg_owned:-no}" || result=1
    fi
    rootpxe_startup_usr_owned=no; rootpxe_startup_usr_mount=""
    return "$result"
}
rootpxe_startup_probe_root_marker() {
    local root="$1" disk="$rootpxe_startup_probe_disk" result=1 path
    for path in /etc/os-release /usr/lib/os-release; do
        rootpxe_startup_resolve_target "$root" "$path" file >/dev/null && return 0
    done
    # 独立 /usr 的 os-release 只能在证明其设备属于已许可目标后读取。
    if rootpxe_startup_mount_usr "$root" "$disk" ro; then
        for path in /etc/os-release /usr/lib/os-release; do
            rootpxe_startup_resolve_target "$root" "$path" file >/dev/null && result=0
        done
    else result=2; fi
    rootpxe_startup_cleanup_usr || return 2
    if [[ $result -eq 1 ]]; then
        for path in /etc/os-release /usr/lib/os-release; do [[ ! -e $root$path && ! -L $root$path ]] || result=2; done
    fi
    return "$result"
}
rootpxe_startup_mount_target() {
    local device="$1" fs="$2" subvol="$3" work="$4" borrowed options
    rootpxe_startup_root_owned=no; rootpxe_startup_mounted_root=""
    borrowed=$(findmnt -rn -S "$device" -o TARGET) || borrowed=""
    if [[ -n $borrowed ]]; then
        [[ $borrowed != *$'\n'* && -d $borrowed && ! -L $borrowed ]] || return 1
        rootpxe_startup_mount_matches "$borrowed" "$device" rw "$subvol" || return 1
        rootpxe_startup_mounted_root="$borrowed"
    else
        mkdir -m 700 "$work/root" || return 1
        options=$(rootpxe_linux_mount_options rw "$fs" "$subvol") || return 1
        mount -t "$fs" -o "$options" "$device" "$work/root" || return 1
        rootpxe_startup_root_owned=yes; rootpxe_startup_mounted_root="$work/root"
        rootpxe_startup_mount_matches "$work/root" "$device" rw "$subvol" || return 1
    fi
}
rootpxe_startup_probe_workspace_remove() {
    local work="$1" directory
    [[ $work == /tmp/rootpxe-startup-mount.* && -d $work && ! -L $work ]] || return 1
    for directory in "$work/root" "$work/probe"; do
        [[ ! -e $directory ]] || { [[ -d $directory && ! -L $directory ]] && ! mountpoint -q "$directory" && rmdir "$directory"; } || return 1
    done
    rmdir "$work"
}
rootpxe_install_linux_startup_for_disk() {
    local disk="$1" script="$2" hash="$3" expected_candidate="${4:-}" work candidate device fs vg uuid subvol extra activated=no result=0 cleanup_safe=yes
    local rootpxe_startup_probe_disk="$disk" rootpxe_linux_probe_mountpoint
    local rootpxe_startup_mounted_root="" rootpxe_startup_root_owned=no
    local rootpxe_startup_usr_owned=no rootpxe_startup_usr_mount="" rootpxe_startup_usr_vg_name="" rootpxe_startup_usr_vg_uuid="" rootpxe_startup_usr_vg_owned=no
    rootpxe_startup_error=""
    [[ ${taskType:-} == deploy && ${osid:-} == 50 && ${postDeployScriptExecution:-} == linux-systemd-v1 ]] || { rootpxe_startup_fail startup_protocol_invalid; return 1; }
    rootpxe_verify_disk_permit_binding "$disk" deploy_write || { rootpxe_startup_fail startup_disk_permit_invalid; return 1; }
    work=$(mktemp -d /tmp/rootpxe-startup-mount.XXXXXX) || return 1
    rootpxe_linux_probe_mountpoint="$work/probe"
    candidate=$(rootpxe_find_linux_root_filesystem "$disk" "$rootpxe_linux_probe_mountpoint") || result=1
    [[ -z $expected_candidate || $candidate == "$expected_candidate" ]] || result=1
    if [[ $result -eq 0 ]]; then
        IFS='|' read -r device fs vg uuid subvol extra <<<"$candidate"
        [[ -z $extra && $device == /dev/* ]] && rootpxe_linux_root_fstype_supported "$fs" || result=1
    fi
    if [[ $result -eq 0 && -n $vg ]]; then activated=$(rootpxe_linux_activate_vg_if_needed "$disk" "$vg" "$uuid") || result=1; fi
    if [[ $result -eq 0 ]]; then rootpxe_startup_mount_target "$device" "$fs" "$subvol" "$work" || result=1; fi
    if [[ $result -eq 0 && -n $script ]]; then rootpxe_startup_mount_usr "$rootpxe_startup_mounted_root" "$disk" ro || result=1; fi
    if [[ $result -eq 0 ]]; then rootpxe_startup_install_at_root "$rootpxe_startup_mounted_root" "$script" "$hash" || result=1; fi
    rootpxe_startup_cleanup_usr || { result=1; cleanup_safe=no; }
    if [[ $rootpxe_startup_root_owned == yes ]]; then umount "$rootpxe_startup_mounted_root" || { result=1; cleanup_safe=no; }; fi
    if [[ $cleanup_safe == yes ]]; then rootpxe_linux_cleanup_selected_vg "${vg:-}" "${uuid:-}" "$activated" || result=1; fi
    rootpxe_startup_probe_workspace_remove "$work" || result=1
    [[ $result -eq 0 || -n $rootpxe_startup_error ]] || rootpxe_startup_error=startup_root_or_mount_unverified
    return "$result"
}

# 先只读探测全部已许可目标，纯数据盘可无root；确认唯一root后才写一次。
rootpxe_install_linux_startup_for_targets() {
    local script="$1" hash="$2" disk work candidate rc selected="" selected_candidate="" count=0 result=0
    local rootpxe_startup_probe_disk=""
    shift 2
    [[ $# -gt 0 && ${taskType:-} == deploy && ${osid:-} == 50 && ${postDeployScriptExecution:-} == linux-systemd-v1 ]] || return 1
    for disk in "$@"; do
        rootpxe_verify_disk_permit_binding "$disk" deploy_write || { rootpxe_startup_fail startup_disk_permit_invalid; return 1; }
    done
    for disk in "$@"; do
        work=$(mktemp -d /tmp/rootpxe-startup-mount.XXXXXX) || return 1
        rootpxe_startup_probe_disk="$disk"
        if candidate=$(rootpxe_find_linux_root_filesystem "$disk" "$work/probe"); then rc=0; else rc=$?; fi
        rootpxe_startup_probe_workspace_remove "$work" || { rootpxe_startup_fail startup_probe_cleanup_failed; return 1; }
        case $rc in
            0) count=$((count + 1)); selected="$disk"; selected_candidate="$candidate";;
            20) ;; # 数据盘，没有目标Linux根。
            *) rootpxe_startup_fail startup_root_probe_failed; return 1;;
        esac
    done
    [[ $count -eq 1 ]] || { rootpxe_startup_fail startup_roots_not_unique; return 1; }
    rootpxe_install_linux_startup_for_disk "$selected" "$script" "$hash" "$selected_candidate"
}
