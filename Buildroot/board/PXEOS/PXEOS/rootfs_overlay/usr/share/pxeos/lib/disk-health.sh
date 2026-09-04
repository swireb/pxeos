#!/bin/bash
# Read-only, best-effort health facts for physical disks.  This helper must
# never make a capture or deployment fail: a missing tool, timeout, or
# malformed tool output becomes an "unknown" disk health record.

rootpxe_disk_health_limit_text() {
    local value="${1-}" limit="$2"
    printf '%s' "${value:0:limit}"
}

rootpxe_disk_health_run() {
    local output="$1"
    shift
    command -v timeout >/dev/null 2>&1 || return 125
    timeout -k 1 3 "$@" >"$output" 2>/dev/null
}

rootpxe_disk_health_message_for_result() {
    local tool="$1" result="$2" parsed="$3"
    case "$result" in
        0) [[ $parsed == 1 ]] || printf '%s output is invalid' "$tool" ;;
        124) printf '%s timed out' "$tool" ;;
        125) printf 'timeout is unavailable' ;;
        *)
            if [[ $parsed != 1 ]]; then
                printf '%s data is unavailable' "$tool"
            fi
            ;;
    esac
}

rootpxe_disk_health_collect_disk() {
    local device="$1" tran="$2" smart_file nvme_file smart_rc=125 nvme_rc=125 smart_parsed=0 nvme_parsed=0 smart_read_issue=0 smart_failed=0 smart_history_issue=0 smart_reported_rc message smart_message nvme_message jq_rc
    smart_file=$(mktemp /tmp/rootpxe-smart.XXXXXX) || return 1
    nvme_file=$(mktemp /tmp/rootpxe-nvme.XXXXXX) || { rm -f -- "$smart_file"; return 1; }
    chmod 600 "$smart_file" "$nvme_file" 2>/dev/null || true

    if command -v smartctl >/dev/null 2>&1; then
        rootpxe_disk_health_run "$smart_file" smartctl -a -j "$device"
        smart_rc=$?
        jq -e 'type == "object"' "$smart_file" >/dev/null 2>&1 && smart_parsed=1
        # smartctl returns a bitmask.  Trust a high-bit status only when its
        # JSON report echoes the same exit status, so signal/timeout results
        # cannot be mistaken for SMART health bits.
        smart_reported_rc=$(jq -er '.smartctl.exit_status | if type == "number" and floor == . and . >= 0 and . <= 255 then tostring else error("exit status") end' "$smart_file" 2>/dev/null || true)
        if [[ $smart_rc =~ ^[0-9]+$ && $smart_rc -ne 124 && $smart_rc -ne 125 && $smart_rc -ne 126 && $smart_rc -ne 127 && ( $smart_rc -lt 128 || $smart_reported_rc == "$smart_rc" ) ]]; then
            (( (smart_rc & 7) != 0 )) && smart_read_issue=1
            (( (smart_rc & 24) != 0 )) && smart_failed=1
            (( (smart_rc & 224) != 0 )) && smart_history_issue=1
        fi
    else
        smart_rc=126
    fi

    case "${tran,,}" in
        nvme) ;;
        *) [[ $device == /dev/nvme[0-9]*n[0-9]* ]] || tran="${tran,,}" ;;
    esac
    if [[ ${tran,,} == nvme || $device == /dev/nvme[0-9]*n[0-9]* ]]; then
        tran=nvme
        if command -v nvme >/dev/null 2>&1; then
            rootpxe_disk_health_run "$nvme_file" nvme smart-log -o json "$device"
            nvme_rc=$?
            jq -e 'type == "object"' "$nvme_file" >/dev/null 2>&1 && nvme_parsed=1
        else
            nvme_rc=126
        fi
    fi

    smart_message=$(rootpxe_disk_health_message_for_result smartctl "$smart_rc" "$smart_parsed")
    nvme_message=""
    [[ ${tran,,} == nvme ]] && nvme_message=$(rootpxe_disk_health_message_for_result nvme "$nvme_rc" "$nvme_parsed")
    message=$(printf '%s\n%s\n' "$smart_message" "$nvme_message" | awk 'NF { if (seen++) printf "; "; printf "%s", $0 }')
    rootpxe_disk_health_limit_text "$message" 512 >"$smart_file.message"

    jq -cn \
        --arg device "$(rootpxe_disk_health_limit_text "$device" 128)" \
        --arg tran "$tran" \
        --argjson smart_rc "$smart_rc" --argjson nvme_rc "$nvme_rc" \
        --argjson smart_parsed "$smart_parsed" --argjson nvme_parsed "$nvme_parsed" \
        --argjson smart_read_issue "$smart_read_issue" --argjson smart_failed "$smart_failed" --argjson smart_history_issue "$smart_history_issue" \
        --rawfile smart "$smart_file" --rawfile nvme "$nvme_file" --rawfile message "$smart_file.message" '
        def object_or_null($text): try ($text | fromjson | if type == "object" then . else null end) catch null;
        def bounded($limit): if type == "string" then .[0:$limit] else null end;
        def decimal:
          if type == "string" and test("^[0-9]+$") then .
          elif type == "number" and . >= 0 and floor == . then tostring
          else null end;
        def canonical_decimal:
          decimal as $value |
          if $value == null then null
          else ($value | sub("^0+"; "") | if . == "" then "0" else . end | if length <= 128 then . else null end) end;
        def positive: decimal as $value | $value != null and ($value | test("^0+$") | not);
        def small_number:
          if type == "number" and floor == . then .
          elif type == "string" and test("^[0-9]+$") then tonumber
          else null end;
        def first_value($values): [$values[] | select(. != null)] | first;
        (object_or_null($smart)) as $smart |
        (object_or_null($nvme)) as $nvme |
        ($tran | ascii_downcase) as $reported_tran |
        (if $reported_tran == "nvme" or ($device | test("/nvme[0-9]+n[0-9]+$")) then "nvme"
         elif $reported_tran == "sata" then "sata"
         elif $reported_tran == "sas" then "sas"
         else "unknown" end) as $transport |
        (if $smart == null then null
         else first_value([$smart.model_name?, $smart.model_number?, $smart.device.model_name?, ([ $smart.scsi_vendor?, $smart.scsi_product? ] | map(select(type == "string" and length > 0)) | join(" "))]) | bounded(256) end) as $model |
        (if $smart == null then null else first_value([$smart.serial_number?, $smart.serial_number_raw?, $smart.device.serial_number?]) | bounded(256) end) as $serial |
        (if $smart == null then null elif ($smart.smart_status.passed? | type) == "boolean" then $smart.smart_status.passed else null end) as $passed |
        (if $smart == null then null else first_value([$smart.temperature.current?, $smart.temperature.current_celsius?]) | small_number end) as $smart_temperature_c |
        (if $nvme == null then null else $nvme.temperature_celsius? | small_number end) as $nvme_temperature_c |
        (if $nvme == null then null else $nvme.temperature? | small_number end) as $nvme_temperature_k |
        (if $smart_temperature_c != null then $smart_temperature_c elif $nvme_temperature_c != null then $nvme_temperature_c elif $nvme_temperature_k != null then ($nvme_temperature_k - 273) else null end) as $temperature_c |
        (if $nvme == null then null else first_value([$nvme.power_on_hours?, $nvme.power_on_time_hours?]) | canonical_decimal end) as $nvme_hours |
        (if $smart == null then null else first_value([$smart.power_on_time.hours?, $smart.nvme_smart_health_information_log.power_on_hours?]) | canonical_decimal end) as $smart_hours |
        (if $nvme_hours != null then $nvme_hours else $smart_hours end) as $hours |
        (if $nvme == null then null else first_value([$nvme.percent_used?, $nvme.percentage_used?]) | small_number end) as $nvme_used |
        (if $smart == null then null else $smart.nvme_smart_health_information_log.percentage_used? | small_number end) as $smart_used |
        (if $nvme_used != null then $nvme_used else $smart_used end) as $used |
        (if $nvme == null then null else first_value([$nvme.avail_spare?, $nvme.available_spare?]) | small_number end) as $nvme_spare |
        (if $smart == null then null else $smart.nvme_smart_health_information_log.available_spare? | small_number end) as $smart_spare |
        (if $nvme_spare != null then $nvme_spare else $smart_spare end) as $spare |
        (if $nvme == null then null else first_value([$nvme.critical_warning?, $nvme.criticalWarning?]) | small_number end) as $nvme_warning |
        (if $smart == null then null else $smart.nvme_smart_health_information_log.critical_warning? | small_number end) as $smart_warning |
        (if $nvme_warning != null then $nvme_warning else $smart_warning end) as $critical |
        (if $nvme == null then null else $nvme.media_errors? | canonical_decimal end) as $nvme_errors |
        (if $smart == null then null else $smart.nvme_smart_health_information_log.media_errors? | canonical_decimal end) as $smart_errors |
        (if $nvme_errors != null then $nvme_errors else $smart_errors end) as $media_errors |
        (if $smart == null then null else first_value([$smart.scsi_grown_defect_list?, $smart.scsi_grown_defect_list.grown_defect_list?]) | canonical_decimal end) as $sas_grown |
        (if $smart == null then null else $smart.scsi_error_counter_log.read.total_uncorrected_errors? | canonical_decimal end) as $sas_read_errors |
        (if $smart == null then null else $smart.scsi_error_counter_log.write.total_uncorrected_errors? | canonical_decimal end) as $sas_write_errors |
        (if $smart == null then null else $smart.scsi_error_counter_log.verify.total_uncorrected_errors? | canonical_decimal end) as $sas_verify_errors |
        (if $smart == null then null else $smart.scsi_non_medium_error_count? | canonical_decimal end) as $sas_non_medium_errors |
        (if $smart == null then [] else [$smart.ata_smart_attributes.table[]? | select(.id == 5) | (.raw.value? // .raw.string?) | canonical_decimal] end | first) as $reallocated |
        (if $smart == null then [] else [$smart.ata_smart_attributes.table[]? | select(.id == 197) | (.raw.value? // .raw.string?) | canonical_decimal] end | first) as $pending |
        (if $smart == null then [] else [$smart.ata_smart_attributes.table[]? | select(.id == 198) | (.raw.value? // .raw.string?) | canonical_decimal] end | first) as $uncorrectable |
        (($critical != null and $critical != 0) or $smart_failed == 1 or $passed == false) as $failed |
        (($reallocated | positive) or ($pending | positive) or ($uncorrectable | positive) or ($media_errors | positive) or ($sas_grown | positive) or ($sas_read_errors | positive) or ($sas_write_errors | positive) or ($sas_verify_errors | positive) or ($sas_non_medium_errors | positive) or $smart_history_issue == 1 or ($used != null and $used >= 100)) as $warning |
        (($passed == true and $smart_read_issue == 0 and $smart_rc == 0) or ($transport == "nvme" and $nvme_parsed == 1 and $nvme_rc == 0 and $critical == 0)) as $healthy_evidence |
        ((if ($message | length) > 0 then ($message | rtrimstr("\n") | .[0:512]) else "" end)) as $base_message |
        (($sas_grown | positive) or ($sas_read_errors | positive) or ($sas_write_errors | positive) or ($sas_verify_errors | positive) or ($sas_non_medium_errors | positive)) as $sas_problem |
        (if $sas_problem then (($base_message + (if ($base_message | length) > 0 then "; " else "" end) + "SAS error counters are nonzero") | .[0:512]) else $base_message end) as $final_message |
        {device:$device, transport:$transport,
         status:(if $failed then "failed" elif $warning then "warning" elif $healthy_evidence then "healthy" else "unknown" end)}
        + (if $model != null then {model:$model} else {} end)
        + (if $serial != null then {serial:$serial} else {} end)
        + (if $passed != null then {smartPassed:$passed} else {} end)
        + (if $temperature_c != null and $temperature_c >= -60 and $temperature_c <= 200 then {temperatureC:$temperature_c} else {} end)
        + (if $hours != null and ($hours | tonumber) <= 9007199254740991 then {powerOnHours:($hours | tonumber)} else {} end)
        + (if $used != null and $used >= 0 and $used <= 255 then {percentageUsed:$used} else {} end)
        + (if $spare != null and $spare >= 0 and $spare <= 100 then {availableSpare:$spare} else {} end)
        + (if $critical != null and $critical >= 0 and $critical <= 255 then {criticalWarning:$critical} else {} end)
        + (if $media_errors != null then {mediaErrors:$media_errors} else {} end)
        + (if $reallocated != null then {reallocatedSectors:$reallocated} else {} end)
        + (if $pending != null then {pendingSectors:$pending} else {} end)
        + (if $uncorrectable != null then {uncorrectableSectors:$uncorrectable} else {} end)
        + (if ($final_message | length) > 0 then {message:$final_message} else {} end)
    '
    jq_rc=$?
    rm -f -- "$smart_file" "$nvme_file" "$smart_file.message"
    return "$jq_rc"
}

rootpxe_disk_health_unknown_record() {
    local device="$1" tran="$2" message="$3" transport=unknown
    case "${tran,,}" in sata|sas|nvme) transport="${tran,,}" ;; esac
    [[ $device == /dev/nvme[0-9]*n[0-9]* ]] && transport=nvme
    jq -cn --arg device "$(rootpxe_disk_health_limit_text "$device" 128)" --arg transport "$transport" --arg message "$(rootpxe_disk_health_limit_text "$message" 512)" \
        '{device:$device,transport:$transport,status:"unknown",message:$message}'
}

rootpxe_collect_disk_health() {
    local lsblk_file rows_file output_file device tran row count=0 started elapsed budget
    local -a disk_rows=()
    command -v lsblk >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    lsblk_file=$(mktemp /tmp/rootpxe-lsblk.XXXXXX) || return 1
    rows_file=$(mktemp /tmp/rootpxe-disk-health.XXXXXX) || { rm -f -- "$lsblk_file"; return 1; }
    output_file=$(mktemp /tmp/rootpxe-disk-health-json.XXXXXX) || { rm -f -- "$lsblk_file" "$rows_file"; return 1; }
    chmod 600 "$lsblk_file" "$rows_file" "$output_file" 2>/dev/null || true
    if ! rootpxe_disk_health_run "$lsblk_file" lsblk --json --output PATH,TYPE,TRAN; then
        rm -f -- "$lsblk_file" "$rows_file" "$output_file"
        return 1
    fi
    jq -e 'type == "object" and (.blockdevices | type) == "array"' "$lsblk_file" >/dev/null 2>&1 || {
        rm -f -- "$lsblk_file" "$rows_file" "$output_file"
        return 1
    }
    mapfile -t disk_rows < <(jq -r '.. | objects | select(.type? == "disk" and (.path? | type) == "string" and (.path | test("^/dev/(loop|ram|zram|dm-|md)"; "i") | not)) | [.path, (.tran // "")] | @tsv' "$lsblk_file" 2>/dev/null | awk '!seen[$1]++' | head -n 64)
    budget=${rootpxe_disk_health_budget_seconds:-30}
    [[ $budget =~ ^[0-9]+$ ]] || budget=30
    started=$SECONDS
    for row in "${disk_rows[@]}"; do
        IFS=$'\t' read -r device tran <<<"$row"
        [[ -n $device ]] || continue
        elapsed=$((SECONDS - started))
        if (( elapsed >= budget )); then
            rootpxe_disk_health_unknown_record "$device" "$tran" 'collection time limit reached' >>"$rows_file" || true
        else
            rootpxe_disk_health_collect_disk "$device" "$tran" >>"$rows_file" || rootpxe_disk_health_unknown_record "$device" "$tran" 'health data is unavailable' >>"$rows_file" || true
        fi
        ((++count >= 64)) && break
    done
    jq -cn --rawfile rows "$rows_file" '{version:1,disks:($rows | split("\n") | map(select(length > 0) | fromjson))}' >"$output_file" 2>/dev/null || { rm -f -- "$lsblk_file" "$rows_file" "$output_file"; return 1; }
    # The field caps above keep normal 64-disk reports below the service
    # limit.  Keep every disk and its status if an unusual payload still
    # exceeds the bound; failed disks are never dropped.
    jq -c 'if (tojson | utf8bytelength) <= 131072 then . else {version:1,disks:[.disks[] | {device,transport,status}]} end' "$output_file" 2>/dev/null || { rm -f -- "$lsblk_file" "$rows_file" "$output_file"; return 1; }
    rm -f -- "$lsblk_file" "$rows_file" "$output_file"
}

rootpxe_send_disk_health() {
    local disk_health
    case "${taskType:-}" in deploy|capture) ;; *) return 0 ;; esac
    rootpxe_require_task_context >/dev/null 2>&1 || return 0
    disk_health=$(rootpxe_collect_disk_health) || {
        declare -F rootpxe_console_message >/dev/null 2>&1 && rootpxe_console_message WARN 'Disk health inventory was not collected.'
        return 0
    }
    jq -e '.version == 1 and (.disks | type) == "array" and (.disks | length) <= 64 and (tojson | utf8bytelength) <= 131072' <<<"$disk_health" >/dev/null 2>&1 || return 0
    curl -Lksf --connect-timeout 5 --max-time 20 \
        --data-urlencode "taskid=$taskid" \
        --data-urlencode "token=$task_token" \
        --data-urlencode "mac=$mac" \
        --data-urlencode "diskHealth=$disk_health" \
        "${rootpxe_api}inventory" >/dev/null 2>&1 || {
            declare -F rootpxe_console_message >/dev/null 2>&1 && rootpxe_console_message WARN 'Disk health inventory was not sent.'
            return 0
        }
    return 0
}
