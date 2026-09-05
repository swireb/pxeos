#!/bin/bash
# Read a reged -x export without ever opening the registry hive for writing.
# MountedDevices values are REG_BINARY and map a Windows drive letter to the
# original volume identity.  The caller owns identity interpretation and any
# device probing; this module preserves the exported byte sequence verbatim.

rootpxe_display_windows_reg_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

rootpxe_display_windows_reg_unescape_name() {
    local input="$1" output="" character escaped
    local index=0 length=${#input}
    while (( index < length )); do
        character=${input:index:1}
        if [[ $character == \\ ]]; then
            index=$((index + 1))
            (( index < length )) || return 1
            escaped=${input:index:1}
            case "$escaped" in
                \\|\") output+="$escaped" ;;
                *) return 1 ;;
            esac
        else
            output+="$character"
        fi
        index=$((index + 1))
    done
    printf '%s' "$output"
}

# Print continuation (0 or 1) and a lower-case, comma-free hex string.  reged
# uses a trailing comma plus backslash to continue onto the next CRLF line.
rootpxe_display_windows_reg_hex_fragment() {
    local fragment="$1" continuation=0 compact
    fragment=${fragment//[[:space:]]/}
    [[ -n $fragment ]] || return 1
    if [[ $fragment == *\\ ]]; then
        continuation=1
        fragment=${fragment%\\}
        [[ $fragment =~ ^([[:xdigit:]]{2},)+$ ]] || return 1
    else
        [[ $fragment =~ ^[[:xdigit:]]{2}(,[[:xdigit:]]{2})*$ ]] || return 1
    fi
    compact=${fragment//,/}
    printf '%s|%s' "$continuation" "${compact,,}"
}

rootpxe_display_windows_parse_reg() {
    local export_file="$1" line trimmed lower section name_escaped name lower_name rhs rhs_lower
    local header_seen=0 mounted_sections=0 in_mounted=0 pending_drive="" pending_hex=""
    local fragment continuation compact letter drive output="" drive_pattern='^\\dosdevices\\([a-z]):$'
    local -A volume_by_drive=()

    [[ -f $export_file && -r $export_file ]] || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        trimmed=$(rootpxe_display_windows_reg_trim "$line") || return 1

        if (( ! header_seen )); then
            [[ -z $trimmed ]] && continue
            lower=${trimmed,,}
            [[ $lower == regedit4 || $lower == 'windows registry editor version 5.00' ]] || return 1
            header_seen=1
            continue
        fi

        if [[ -n $pending_drive ]]; then
            fragment=$(rootpxe_display_windows_reg_hex_fragment "$trimmed") || return 1
            continuation=${fragment%%|*}
            compact=${fragment#*|}
            pending_hex+="$compact"
            if [[ $continuation == 1 ]]; then
                continue
            fi
            [[ -n ${volume_by_drive[$pending_drive]+present} ]] && return 1
            volume_by_drive[$pending_drive]=$pending_hex
            pending_drive=""
            pending_hex=""
            continue
        fi

        if [[ $trimmed =~ ^\[[^][]+\]$ ]]; then
            section=${trimmed:1:${#trimmed}-2}
            lower=${section,,}
            if [[ $lower == 'hkey_local_machine\system\mounteddevices' ]]; then
                mounted_sections=$((mounted_sections + 1))
                (( mounted_sections == 1 )) || return 1
                in_mounted=1
            else
                in_mounted=0
            fi
            continue
        fi

        (( in_mounted )) || continue
        [[ $trimmed =~ ^\"(.*)\"[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        name_escaped=${BASH_REMATCH[1]}
        rhs=${BASH_REMATCH[2]}
        name=$(rootpxe_display_windows_reg_unescape_name "$name_escaped") || return 1
        lower_name=${name,,}
        [[ $lower_name =~ $drive_pattern ]] || continue
        letter=${BASH_REMATCH[1]^^}
        drive="$letter:"
        rhs_lower=${rhs,,}
        [[ $rhs_lower == hex:* ]] || return 1
        fragment=$(rootpxe_display_windows_reg_hex_fragment "${rhs#*:}") || return 1
        continuation=${fragment%%|*}
        compact=${fragment#*|}
        pending_drive=$drive
        pending_hex=$compact
        if [[ $continuation == 0 ]]; then
            [[ -n ${volume_by_drive[$pending_drive]+present} ]] && return 1
            volume_by_drive[$pending_drive]=$pending_hex
            pending_drive=""
            pending_hex=""
        fi
    done <"$export_file"

    (( header_seen && mounted_sections == 1 )) || return 1
    [[ -z $pending_drive ]] || return 1

    for letter in {A..Z}; do
        drive="$letter:"
        [[ -n ${volume_by_drive[$drive]+present} ]] || continue
        if [[ -n $output ]]; then output+=','; fi
        output+="{\"driveLetter\":\"$drive\",\"volumeId\":\"${volume_by_drive[$drive]}\"}"
    done
    printf '[%s]\n' "$output"
}
