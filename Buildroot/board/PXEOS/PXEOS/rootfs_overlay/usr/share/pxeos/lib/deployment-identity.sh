#!/bin/bash
# 冻结部署身份 v1：Windows 计算机名/Sysprep 与原生 NoCloud 注入回执。
. "$(dirname "${BASH_SOURCE[0]}")/task-http.sh" || return 1

rootpxe_deployment_identity_policy_enabled() {
    [[ -r ${deploymentIdentityPolicyFile:-} ]] || return 1
    [[ ${changeHostname:-false} == true ]] || jq -e '.version == 1 and ((.systemIdentity.sysprep == true) or (.cloudInit == true))' "$deploymentIdentityPolicyFile" >/dev/null 2>&1
}

rootpxe_deployment_identity_private_enabled() {
    rootpxe_deployment_identity_windows_policy_enabled || return 1
    jq -e '.version == 1 and .systemIdentity.sysprep == true' "$deploymentIdentityPolicyFile" >/dev/null 2>&1
}

rootpxe_deployment_identity_request_private() {
    local api="${pxeapi:-${web:-}}" request response body code file
    rootpxe_deployment_identity_private_enabled || return 0
    [[ -n $api && ${taskid:-} =~ ^[1-9][0-9]*$ && -n ${task_token:-} && -n ${mac:-} && ${progress_attempt:-} =~ ^[1-9][0-9]*$ ]] || return 1
    api="${api%/}/"
    request=$(jq -cn --argjson taskId "$taskid" --arg token "$task_token" --arg mac "$mac" --argjson attempt "$progress_attempt" '{taskId:$taskId,token:$token,mac:$mac,attempt:$attempt}') || return 1
    response=$(rootpxe_task_curl -ks --connect-timeout 10 --max-time 30 -H 'Content-Type: application/json' --data-binary "$request" -w $'\n%{http_code}' "${api}deployment-initialization" 2>/dev/null) || return 1
    code=${response##*$'\n'}; body=${response%$'\n'*}
    [[ $code == 200 ]] || return 1
    jq -e '.version == 1 and (.unattendXml | type == "string") and (keys == ["unattendXml","version"])' >/dev/null 2>&1 <<<"$body" || return 1
    file=$(mktemp /tmp/rootpxe-deployment-initialization.XXXXXX) || return 1
    chmod 0600 "$file" || { rm -f -- "$file"; return 1; }
    jq -c '{version:1,unattendXml:.unattendXml}' <<<"$body" >"$file" || { rm -f -- "$file"; return 1; }
    rootpxe_deployment_initialization_private_file="$file"; export rootpxe_deployment_initialization_private_file
}

rootpxe_deployment_identity_cleanup_private() {
    local file="${rootpxe_deployment_initialization_private_file:-}"
    if [[ -n $file ]]; then
        [[ -f $file && ! -L $file && $file == /tmp/rootpxe-deployment-initialization.* ]] && rm -f -- "$file"
    fi
    unset rootpxe_deployment_initialization_private_file
}

rootpxe_deployment_identity_private_value() {
    local filter="$1" file="${rootpxe_deployment_initialization_private_file:-}"
    [[ -r $file && ! -L $file ]] || return 1
    jq -er "$filter" "$file"
}

rootpxe_deployment_identity_windows_policy_enabled() {
    rootpxe_deployment_identity_policy_enabled || return 1
    case ${osid:-} in 2|5|6|7|9|10) ;; *) return 1;; esac
}

rootpxe_deployment_identity_windows_hostname_capability_installed() {
    local tool
    for tool in jq ntfs-3g reged rootpxe-offline-identities; do
        command -v "$tool" >/dev/null 2>&1 || return 1
    done
}

rootpxe_deployment_identity_windows_sysprep_capability_installed() {
    local tool
    for tool in jq ntfs-3g xml; do
        command -v "$tool" >/dev/null 2>&1 || return 1
    done
}

rootpxe_deployment_identity_request_plan() {
    local api="${pxeapi:-${web:-}}" request response body code file
    rootpxe_deployment_identity_policy_enabled || return 0
    [[ -n $api && ${taskid:-} =~ ^[1-9][0-9]*$ && -n ${task_token:-} && -n ${mac:-} && ${progress_attempt:-} =~ ^[1-9][0-9]*$ ]] || return 1
    api="${api%/}/"
    request=$(jq -cn --argjson taskId "$taskid" --arg token "$task_token" --arg mac "$mac" --argjson attempt "$progress_attempt" '{taskId:$taskId,token:$token,mac:$mac,attempt:$attempt}') || return 1
    response=$(rootpxe_task_curl -ks --connect-timeout 10 --max-time 30 -H 'Content-Type: application/json' --data-binary "$request" -w $'\n%{http_code}' "${api}deployment-identity-plan" 2>/dev/null) || return 1
    code=${response##*$'\n'}; body=${response%$'\n'*}
    [[ $code == 200 ]] || return 1
    file=$(mktemp /tmp/rootpxe-deployment-identity-plan.XXXXXX) || return 1
    chmod 0600 "$file" || { rm -f -- "$file"; return 1; }
    printf '%s' "$body" >"$file" || { rm -f -- "$file"; return 1; }
    jq -e --argjson attempt "$progress_attempt" '.plan.version == 1 and (.plan.planId|type == "string" and length > 0) and (.planHash|type == "string" and test("^[0-9a-f]{64}$")) and .attempt == $attempt' "$file" >/dev/null || { rm -f -- "$file"; return 1; }
    rootpxe_deployment_identity_plan_file="$file"; export rootpxe_deployment_identity_plan_file
}

rootpxe_deployment_identity_report_result() {
    local hostname="$1" sysprep="$2" cloud_init="$3" api request response http_code
    rootpxe_deployment_identity_policy_enabled || return 0
    [[ -r ${rootpxe_deployment_identity_plan_file:-} ]] || return 1
    case "$hostname:$sysprep:$cloud_init" in *[!a-z:]*|'') return 1;; esac
    [[ $hostname =~ ^(true|false)$ && $sysprep =~ ^(true|false)$ && $cloud_init =~ ^(true|false)$ ]] || return 1
    api="${pxeapi:-${web:-}}"; [[ -n $api ]] || return 1
    request=$(jq -cn --argjson taskId "$taskid" --arg token "$task_token" --arg mac "$mac" --arg planId "$(jq -r '.plan.planId' "$rootpxe_deployment_identity_plan_file")" --arg planHash "$(jq -r '.planHash' "$rootpxe_deployment_identity_plan_file")" --argjson attempt "$progress_attempt" --argjson hostname "$hostname" --argjson sysprep "$sysprep" --argjson cloudInit "$cloud_init" '{taskId:$taskId,token:$token,mac:$mac,planId:$planId,planHash:$planHash,attempt:$attempt,result:{hostname:$hostname,sysprep:$sysprep,cloudInit:$cloudInit}}') || return 1
    response=$(rootpxe_task_curl -ks --connect-timeout 10 --max-time 30 -H 'Content-Type: application/json' --data-binary "$request" -w $'\n%{http_code}' "${api}deployment-identity-result" 2>/dev/null) || return 1
    http_code=${response##*$'\n'}
    [[ $http_code =~ ^2[0-9][0-9]$ ]]
}
