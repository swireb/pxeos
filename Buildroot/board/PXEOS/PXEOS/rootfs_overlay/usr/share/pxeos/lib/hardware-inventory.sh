#!/bin/bash
# Read-only hardware information from the authenticated task's PXEOS runtime.

rootpxe_hardware_probe() {
    local output="$1"
    shift
    timeout -k 1 3 "$@" >"$output" 2>/dev/null || : >"$output"
}

rootpxe_hardware_cpu_topology() {
    local sys="$1" cpu online package core
    for cpu in "$sys"/devices/system/cpu/cpu[0-9]*; do
        [[ ${cpu##*/} =~ ^cpu[0-9]+$ && -r $cpu/topology/physical_package_id ]] || continue
        online=1
        if [[ -r $cpu/online ]]; then
            read -r online <"$cpu/online" || continue
        fi
        [[ $online == 1 ]] || continue
        read -r package <"$cpu/topology/physical_package_id" || continue
        [[ $package =~ ^[0-9]+$ ]] || continue
        core=
        if [[ -r $cpu/topology/core_id ]]; then
            read -r core <"$cpu/topology/core_id" || core=
        fi
        printf '%s\t%s\n' "$package" "$core"
    done
}

rootpxe_hardware_network_interfaces() {
    local sys="$1" interface device address compact speed
    for interface in "$sys"/class/net/*; do
        # Software-only devices such as loopback and bridges have no parent
        # hardware device. Their MACs must not duplicate a physical NIC.
        [[ -e $interface/device && -r $interface/address ]] || continue
        read -r address <"$interface/address" || continue
        compact=${address//:/}
        [[ $compact =~ ^[0-9a-fA-F]{12}$ && $compact != 000000000000 ]] || continue
        device=$(readlink -f "$interface/device") || continue
        speed=
        if [[ -r $interface/speed ]]; then
            { read -r speed <"$interface/speed"; } 2>/dev/null || speed=
        fi
        printf '%s\t%s\t%s\t%s\n' "${interface##*/}" "${device##*/}" "${compact,,}" "$speed"
    done
}

rootpxe_hardware_pci_paths() {
    local sys="$1" device class physical part
    local -a parts
    for device in "$sys"/bus/pci/devices/*; do
        [[ -r $device/class ]] || continue
        read -r class <"$device/class" || continue
        case $class in 0x02*|0x03*) ;; *) continue ;; esac
        physical=$(readlink -f "$device") || continue
        IFS=/ read -r -a parts <<<"$physical"
        printf '%s' "${device##*/}"
        for part in "${parts[@]}"; do
            if [[ $part =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
                printf '\t%s' "${part,,}"
            fi
        done
        printf '\n'
    done
}

rootpxe_hardware_pxe_boot_mac() {
    local cmdline="$1" arg address= count=0
    local -a args=()
    [[ -r $cmdline ]] || return 0
    read -r -a args <"$cmdline" || true
    for arg in "${args[@]}"; do
        case $arg in
            pxe_boot_mac=*)
                address=${arg#*=}
                count=$((count + 1))
                ;;
        esac
    done
    if [[ $count == 1 && $address =~ ^[0-9a-fA-F]{12}$ && $address != 000000000000 ]]; then
        printf '%s' "${address,,}"
    fi
}

rootpxe_collect_hardware_inventory() (
    local sys="${1:-/sys}" cpuinfo="${2:-/proc/cpuinfo}" cmdline="${3:-/proc/cmdline}"
    local library_dir="${BASH_SOURCE[0]%/*}" temporary slot
    export LC_ALL=C
    command -v jq >/dev/null && command -v timeout >/dev/null || return 1
    temporary=$(mktemp -d /tmp/rootpxe-hardware-inventory.XXXXXX) || return 1
    trap 'rm -rf -- "$temporary"' EXIT

    rootpxe_hardware_probe "$temporary/dmi" dmidecode --type 4,9,17,41
    rootpxe_hardware_probe "$temporary/lshw" lshw -json -class display -class network
    rootpxe_hardware_probe "$temporary/lsblk" lsblk --bytes --json --output PATH,TYPE,TRAN,SIZE,MODEL
    if ! rootpxe_physical_disk_entries json "$temporary/lsblk" >"$temporary/disks" 2>/dev/null; then
        : >"$temporary/disks"
    fi
    rootpxe_hardware_cpu_topology "$sys" >"$temporary/cpus"
    rootpxe_hardware_network_interfaces "$sys" >"$temporary/nics"
    rootpxe_hardware_pci_paths "$sys" >"$temporary/pci"
    for slot in "$sys"/bus/pci/slots/*/address; do
        if [[ -r $slot ]]; then
            cat "$slot"
        fi
    done >"$temporary/slots"
    [[ -r $cpuinfo ]] || cpuinfo=/dev/null

    jq -nce --rawfile dmi "$temporary/dmi" --rawfile hardware "$temporary/lshw" \
        --slurpfile disks "$temporary/disks" --rawfile topology "$temporary/cpus" \
        --rawfile cpuinfo "$cpuinfo" --rawfile interfaces "$temporary/nics" \
        --rawfile slots "$temporary/slots" --rawfile pci_paths "$temporary/pci" \
        --arg boot_mac "$(rootpxe_hardware_pxe_boot_mac "$cmdline")" \
        -f "$library_dir/hardware-inventory.jq"
)

rootpxe_send_hardware_inventory() {
    local inventory
    case "${taskType:-}" in deploy|capture) ;; *) return 0 ;; esac
    rootpxe_require_task_context >/dev/null 2>&1 || return 0
    if ! inventory=$(rootpxe_collect_hardware_inventory 2>/dev/null); then
        rootpxe_console_message WARN 'Host hardware inventory was not collected.'
        return 0
    fi

    rootpxe_task_curl -ksf --connect-timeout 3 --max-time 5 \
        --data-urlencode "taskid=$taskid" \
        --data-urlencode "token=$task_token" \
        --data-urlencode "mac=$mac" \
        --data-urlencode "hardwareInventory=$inventory" \
        "${rootpxe_api}inventory" >/dev/null 2>&1 || \
        rootpxe_console_message WARN 'Host hardware inventory was not sent.'
    return 0
}
