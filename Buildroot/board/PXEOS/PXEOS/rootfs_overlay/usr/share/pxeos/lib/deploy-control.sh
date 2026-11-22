#!/bin/bash

rootpxe_publish_deploy_control() {
    [[ -n ${rootpxe_deploy_control_dir:-} ]] || return 0
    local file
    file=$(mktemp "$rootpxe_deploy_control_dir/context.XXXXXX") || return 1
    if ! printf '%s\n' "${1:-$execution_token}" "${2-${progress_attempt:-}}" "$rootpxe_storage_boot_id" "$rootpxe_storage_sysuuid" >"$file" ||
       ! mv -f -- "$file" "$rootpxe_deploy_control_dir/context"; then
        rm -f -- "$file"
        return 1
    fi
}

rootpxe_deploy_control_request() {
    local response api=${pxeapi:-$web}
    local -a context tls=(-ks) fields=()
    mapfile -t context <"$rootpxe_deploy_control_dir/context" || return 1
    [[ ${#context[@]} -eq 4 && -n ${context[0]} && -n ${context[2]} ]] || return 1
    if [[ -n ${context[1]} ]]; then
        [[ ${context[1]} =~ ^[1-9][0-9]*$ ]] || return 1
        fields+=(--data-urlencode "attempt=${context[1]}")
    fi
    if [[ ${1:-} == claim ]]; then
        fields+=(--data-urlencode 'deployRetryClaim=true')
    fi
    if [[ ${manual_direct_task:-} == yes ]]; then
        [[ $api == https://* && ${manual_spki_pin:-} =~ ^sha256//[A-Za-z0-9+/]{43}=$ ]] || return 1
        tls+=(--proto '=https' --proto-redir '=https' --max-redirs 0 --pinnedpubkey "$manual_spki_pin")
    fi
    response=$(rootpxe_task_curl "${tls[@]}" --connect-timeout 2 --max-time 4 \
        --data-urlencode "taskid=$taskid" --data-urlencode "mac=$mac" --data-urlencode "token=${context[0]}" \
        --data-urlencode "deployControl=true" --data-urlencode "storageBootId=${context[2]}" --data-urlencode "sysuuid=${context[3]}" "${fields[@]}" \
        -w $'\n%{http_code}' "${api}task-status" 2>/dev/null) || return 1
    [[ ${response##*$'\n'} == 200 ]] || return 1
    printf '%s\n' "${response%$'\n'*}"
}

rootpxe_deploy_poll() {
    local response="${1:-}" status
    if [[ -z $response ]]; then
        response=$(rootpxe_deploy_control_request) || return 1
    fi
    status=$(jq -er '.status | strings' 2>/dev/null <<<"$response") || return 1
    [[ $status == superseded || $status == deleted ]] || return 1
    printf '%s\n' "$status" >"$rootpxe_deploy_control_dir/revocation" || return 1
    : >"$rootpxe_deploy_control_dir/stop"
}

rootpxe_deploy_mounts_to_clean() {
    awk '
        FILENAME == ARGV[1] { original[$1] = 1; next }
        !($1 in original) && ($5 ~ /^\/(storage|ntfs|bcdstore|tmp\/btrfs)(\/|$)/ ||
            $5 ~ /^\/tmp\/rootpxe-(uefi|cloud-mount|display-mount|display-windows|xfs-grow|xfs-restore)\.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]](\/|$)/ ||
            $5 == "/sys/firmware/efi/efivars") { print length($5), $1, $5 }
    ' "$1" "$2"
}

rootpxe_deploy_retry_cleanup() {
    local baseline=$1 current=${2:-/proc/self/mountinfo} mounts path
    [[ -s $baseline && -r $current ]] || return 1
    mounts=$(rootpxe_deploy_mounts_to_clean "$baseline" "$current") || return 1
    [[ -n $mounts ]] || return 0
    # Unmount children before their parents and stacked mounts in reverse order.
    while read -r _ _ path; do
        [[ -n $path ]] || continue
        printf -v path '%b' "$path"
        umount -- "$path" || return 1
    done < <(sort -k1,1nr -k2,2nr <<<"$mounts")
    mounts=$(rootpxe_deploy_mounts_to_clean "$baseline" "$current") || return 1
    [[ -z $mounts ]]
}

rootpxe_run_deployment() (
    local worker="${1:-pxeos.download}" control_parent="${2:-/tmp}"
    umask 077
    rootpxe_deploy_control_dir="$control_parent/pxeos.deploy-control"
    mkdir -m 700 -- "$rootpxe_deploy_control_dir" || return 1
    export rootpxe_deploy_control_dir
    trap 'rm -rf -- "$rootpxe_deploy_control_dir"' EXIT
    trap ': >"$rootpxe_deploy_control_dir/interrupted"; : >"$rootpxe_deploy_control_dir/stop"' HUP INT TERM
    local poller rc state response credential attempt cleanup_warned current_attempt wait_seconds
    local baseline="$rootpxe_deploy_control_dir/mountinfo-before"
    local -a context failure_policy
    while [[ ! -e $rootpxe_deploy_control_dir/interrupted ]]; do
        cat /proc/self/mountinfo >"$baseline" || return 1
        (
            trap 'exit 0' HUP INT TERM
            while [[ ! -e $rootpxe_deploy_control_dir/stop && ! -e $rootpxe_deploy_control_dir/poll-done ]]; do
                if [[ -f $rootpxe_deploy_control_dir/context ]]; then
                    rootpxe_deploy_poll || true
                fi
                sleep 3
            done
        ) &
        poller=$!
        rc=0
        pxeos-deploy-worker "$rootpxe_deploy_control_dir/stop" "$worker" || rc=$?
        : >"$rootpxe_deploy_control_dir/poll-done"
        wait "$poller" 2>/dev/null || true
        [[ ! -e $rootpxe_deploy_control_dir/interrupted ]] || return 75
        [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 75 ]] || return 75
        if [[ ! -f $rootpxe_deploy_control_dir/revocation ]]; then
            [[ $rc -ne 0 ]] || return 0
            [[ -f $rootpxe_deploy_control_dir/context ]] || return "$rc"
            failure_policy=()
            if [[ -f $rootpxe_deploy_control_dir/failure-policy ]]; then
                mapfile -t failure_policy <"$rootpxe_deploy_control_dir/failure-policy" || return 75
                [[ ${#failure_policy[@]} -eq 2 && ${failure_policy[0]} =~ ^[1-9][0-9]{0,11}$ ]] || return 75
                case ${failure_policy[1]} in reboot|shutdown) ;; *) return 75 ;; esac
            fi
            while [[ ! -e $rootpxe_deploy_control_dir/interrupted ]]; do
                wait_seconds=3
                if (( ${#failure_policy[@]} )); then
                    wait_seconds=$(( failure_policy[0] - $(date +%s) ))
                    if (( wait_seconds <= 0 )); then
                        response=$(rootpxe_deploy_control_request) || return 75
                        rootpxe_deploy_poll "$response" && break
                        [[ ! -e $rootpxe_deploy_control_dir/interrupted ]] || return 75
                        jq -es 'length == 1 and .[0].status == "failed"' >/dev/null 2>&1 <<<"$response" || return 75
                        # Only the supervisor may return the action codes.
                        case ${failure_policy[1]} in reboot) return 76 ;; shutdown) return 77 ;; esac
                    fi
                    (( wait_seconds <= 3 )) || wait_seconds=3
                fi
                rootpxe_deploy_poll && break
                sleep "$wait_seconds"
            done
        fi
        [[ ! -e $rootpxe_deploy_control_dir/interrupted ]] || return 75
        read -r state <"$rootpxe_deploy_control_dir/revocation" || return 75
        [[ $state == superseded ]] || return 75

        # The supervisor has reaped the whole worker tree. Check that no
        # deployment-owned mounts remain before claiming a runnable token.
        cleanup_warned=no
        while ! rootpxe_deploy_retry_cleanup "$baseline"; do
            if [[ $cleanup_warned == no ]]; then
                printf '[WARN] Deployment retry is waiting for local mounts to become idle.\n' >&2
                cleanup_warned=yes
            fi
            [[ ! -e $rootpxe_deploy_control_dir/interrupted ]] || return 75
            rootpxe_deploy_poll || true
            read -r state <"$rootpxe_deploy_control_dir/revocation" || return 75
            [[ $state == superseded ]] || return 75
            sleep 3
        done
        mapfile -t context <"$rootpxe_deploy_control_dir/context" || return 75
        current_attempt=${context[1]}
        while [[ ! -e $rootpxe_deploy_control_dir/interrupted ]]; do
            if response=$(rootpxe_deploy_control_request claim); then
                state=$(jq -er '.status | strings' 2>/dev/null <<<"$response") || state=
                case $state in
                    deleted|superseded) return 75 ;;
                    retry)
                        credential=$(jq -er '.executionToken | strings' 2>/dev/null <<<"$response") || return 75
                        attempt=$(jq -er '.progressAttempt | numbers' 2>/dev/null <<<"$response") || return 75
                        [[ $credential =~ ^[A-Za-z0-9._~+/=-]{16,512}$ && $credential != "${context[0]}" && $attempt =~ ^[1-9][0-9]*$ ]] || return 75
                        [[ -z $current_attempt || $attempt -gt $current_attempt ]] || return 75
                        rootpxe_storage_boot_id=${context[2]} rootpxe_storage_sysuuid=${context[3]}
                        rootpxe_publish_deploy_control "$credential" "$attempt" || return 75
                        rootpxe_deploy_retry_token=$credential
                        rootpxe_deploy_retry_attempt=$attempt
                        task_token=$credential
                        export rootpxe_deploy_retry_token rootpxe_deploy_retry_attempt task_token
                        break
                        ;;
                esac
            fi
            sleep 3
        done
        rm -f -- "$rootpxe_deploy_control_dir/stop" "$rootpxe_deploy_control_dir/revocation" "$rootpxe_deploy_control_dir/poll-done" "$rootpxe_deploy_control_dir/failure-policy" || return 75
    done
    return 75
)
