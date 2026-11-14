#!/bin/bash

rootpxe_publish_deploy_control() {
    [[ -n ${rootpxe_deploy_control_dir:-} ]] || return 0
    local file
    file=$(mktemp "$rootpxe_deploy_control_dir/context.XXXXXX") || return 1
    if ! printf '%s\n' "$execution_token" "$progress_attempt" "$rootpxe_storage_boot_id" "$rootpxe_storage_sysuuid" >"$file" ||
       ! mv -f -- "$file" "$rootpxe_deploy_control_dir/context"; then
        rm -f -- "$file"
        return 1
    fi
}

rootpxe_deploy_control_request() {
    local action=${1:-poll} response status api=${pxeapi:-$web}
    local -a context tls=(-ks) request=()
    mapfile -t context <"$rootpxe_deploy_control_dir/context" || return 1
    [[ ${#context[@]} -eq 4 && -n ${context[0]} && ${context[1]} =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ ${manual_direct_task:-} == yes ]]; then
        [[ $api == https://* && ${manual_spki_pin:-} =~ ^sha256//[A-Za-z0-9+/]{43}=$ ]] || return 1
        tls+=(--proto '=https' --proto-redir '=https' --max-redirs 0 --pinnedpubkey "$manual_spki_pin")
    fi
    [[ $action != stopped ]] || request+=(--data-urlencode abortStopped=true)
    response=$(rootpxe_task_curl "${tls[@]}" --connect-timeout 2 --max-time 4 \
        --data-urlencode "taskid=$taskid" --data-urlencode "mac=$mac" --data-urlencode "token=${context[0]}" \
        --data-urlencode "deployAbortControl=true" --data-urlencode "attempt=${context[1]}" --data-urlencode "storageBootId=${context[2]}" --data-urlencode "sysuuid=${context[3]}" \
        "${request[@]}" -w $'\n%{http_code}' "${api}task-status" 2>/dev/null) || return 1
    [[ ${response##*$'\n'} == 200 ]] || return 1
    status=$(jq -er '.status | strings' 2>/dev/null <<<"${response%$'\n'*}") || return 1
    if [[ $action == stopped ]]; then
        [[ $status == cancelled ]]
        return
    fi
    case $status in
        superseded|deleted) : >"$rootpxe_deploy_control_dir/revoked" || return 1 ;;
        aborting) ;;
        *) return 1 ;;
    esac
    : >"$rootpxe_deploy_control_dir/stop"
}

rootpxe_run_deployment() (
    local worker="${1:-pxeos.download}" control_parent="${2:-/tmp}"
    # Explicit retries exec pxeos from this same supervised child tree.
    if [[ -n ${rootpxe_deploy_control_dir:-} ]]; then
        exec "$worker"
    fi
    umask 077
    rootpxe_deploy_control_dir="$control_parent/pxeos.deploy-control"
    mkdir -m 700 -- "$rootpxe_deploy_control_dir" || return 1
    export rootpxe_deploy_control_dir
    trap 'rm -rf -- "$rootpxe_deploy_control_dir"' EXIT
    trap ': >"$rootpxe_deploy_control_dir/stop"' HUP INT TERM
    (
        trap 'exit 0' HUP INT TERM
        while [[ ! -e $rootpxe_deploy_control_dir/stop && ! -e $rootpxe_deploy_control_dir/poll-done ]]; do
            if [[ -f $rootpxe_deploy_control_dir/context ]]; then
                rootpxe_deploy_control_request poll || true
            fi
            sleep 3
        done
    ) &
    local poller=$! rc
    pxeos-deploy-worker "$rootpxe_deploy_control_dir/stop" "$worker"
    rc=$?
    : >"$rootpxe_deploy_control_dir/poll-done"
    wait "$poller" 2>/dev/null || true
    if [[ $rc == 0 || $rc == 1 || $rc == 75 ]] && [[ -f $rootpxe_deploy_control_dir/context ]]; then
        # Also check after normal worker exit to resolve a concurrent abort.
        if [[ -e $rootpxe_deploy_control_dir/stop ]] || rootpxe_deploy_control_request poll; then
            if [[ -e $rootpxe_deploy_control_dir/revoked ]] || { rootpxe_deploy_control_request poll && [[ -e $rootpxe_deploy_control_dir/revoked ]]; }; then
                printf '%s\n' '[INFO] This deployment was revoked and has stopped.'
                return 75
            fi
            for ((tries=0; tries<3; tries++)); do
                if rootpxe_deploy_control_request stopped; then
                    printf '%s\n' '[INFO] Deployment stopped. Boot into PXE again to restart the task.'
                    return 75
                fi
                sleep 1
            done
            printf '%s\n' '[WARN] Deployment stopped. RootPXE has not confirmed the stop.'
            return 75
        fi
    fi
    return "$rc"
)
