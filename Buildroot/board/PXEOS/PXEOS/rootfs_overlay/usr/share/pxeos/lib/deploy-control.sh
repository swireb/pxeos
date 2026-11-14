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
    local response status api=${pxeapi:-$web}
    local -a context tls=(-ks)
    mapfile -t context <"$rootpxe_deploy_control_dir/context" || return 1
    [[ ${#context[@]} -eq 4 && -n ${context[0]} && ${context[1]} =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ ${manual_direct_task:-} == yes ]]; then
        [[ $api == https://* && ${manual_spki_pin:-} =~ ^sha256//[A-Za-z0-9+/]{43}=$ ]] || return 1
        tls+=(--proto '=https' --proto-redir '=https' --max-redirs 0 --pinnedpubkey "$manual_spki_pin")
    fi
    response=$(rootpxe_task_curl "${tls[@]}" --connect-timeout 2 --max-time 4 \
        --data-urlencode "taskid=$taskid" --data-urlencode "mac=$mac" --data-urlencode "token=${context[0]}" \
        --data-urlencode "deployControl=true" --data-urlencode "attempt=${context[1]}" --data-urlencode "storageBootId=${context[2]}" --data-urlencode "sysuuid=${context[3]}" \
        -w $'\n%{http_code}' "${api}task-status" 2>/dev/null) || return 1
    [[ ${response##*$'\n'} == 200 ]] || return 1
    status=$(jq -er '.status | strings' 2>/dev/null <<<"${response%$'\n'*}") || return 1
    [[ $status == superseded || $status == deleted ]] || return 1
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
                rootpxe_deploy_control_request || true
            fi
            sleep 3
        done
    ) &
    local poller=$! rc
    pxeos-deploy-worker "$rootpxe_deploy_control_dir/stop" "$worker"
    rc=$?
    : >"$rootpxe_deploy_control_dir/poll-done"
    wait "$poller" 2>/dev/null || true
    return "$rc"
)
