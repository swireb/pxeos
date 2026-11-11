#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/tests/task-http-test-support.sh"
overlay="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay"
library="$overlay/usr/share/pxeos/lib/hardware-inventory.sh"
checkin="$overlay/bin/pxeos.checkin"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -f $library ]] || fail 'missing hardware inventory library'

mkdir -p "$tmp/bin" "$tmp/sys/class/net" "$tmp/sys/bus/pci/slots/2"
for entry in 'lan0 0000:03:00.0 02:00:00:00:01:01 2500' 'lan1 0000:04:00.0 02:00:00:00:02:02 1000'; do
    read -r interface address interface_mac speed <<<"$entry"
    mkdir -p "$tmp/sys/devices/$address" "$tmp/sys/class/net/$interface"
    ln -s "../../../devices/$address" "$tmp/sys/class/net/$interface/device"
    printf '%s\n' "$interface_mac" >"$tmp/sys/class/net/$interface/address"
    printf '%s\n' "$speed" >"$tmp/sys/class/net/$interface/speed"
done
mkdir -p "$tmp/sys/class/net/bridge0"
printf '%s\n' '02:00:00:00:02:02' >"$tmp/sys/class/net/bridge0/address"
printf '%s\n' '0000:03:00' >"$tmp/sys/bus/pci/slots/2/address"
gpu_path="devices/pci0000:00/0000:00:1c.0/0000:01:00.0"
mkdir -p "$tmp/sys/bus/pci/devices" "$tmp/sys/$gpu_path"
ln -s "../../../$gpu_path" "$tmp/sys/bus/pci/devices/0000:01:00.0"
printf '%s\n' 0x030000 >"$tmp/sys/$gpu_path/class"

cat >"$tmp/dmi" <<'EOF'
Handle 0x0004, DMI type 4, 48 bytes
Processor Information
	Socket Designation: CPU0
	Version: Intel Xeon Silver 4210
	Status: Populated, Enabled
	Core Count: 10
	Core Enabled: 10
	Thread Count: 20

Handle 0x0005, DMI type 4, 48 bytes
Processor Information
	Socket Designation: CPU1
	Version: Intel Xeon Silver 4210
	Status: Populated, Enabled
	Core Count: 10
	Core Enabled: 8
	Thread Count: 20
	Thread Enabled: 16

Handle 0x0006, DMI type 4, 48 bytes
Processor Information
	Socket Designation: CPU2
	Status: Unpopulated

Handle 0x0007, DMI type 17, 40 bytes
Memory Device
	Size: 32 GB
	Locator: DIMM A2
	Type: DDR4
	Speed: 3200 MT/s
	Part Number: KSM32RD4/32MEI
	Serial Number: private-memory-serial

Handle 0x0008, DMI type 17, 40 bytes
Memory Device
	Size: 16 GB
	Locator: DIMM B2
	Type: DDR4
	Speed: 3200 MT/s
	Configured Memory Speed: 2666 MT/s
	Part Number: Other-DIMM

Handle 0x0009, DMI type 17, 40 bytes
Memory Device
	Size: No Module Installed
	Locator: DIMM A1
	Part Number: Not Specified

Handle 0x000A, DMI type 9, 24 bytes
System Slot Information
	Designation: PCIe x16
	Bus Address: 0000:00:1c.0

Handle 0x000B, DMI type 41, 11 bytes
Onboard Device
	Reference Designation: Display
	Type: Video
	Status: Enabled
	Bus Address: 0000:02:00.0

Handle 0x000C, DMI type 41, 11 bytes
Onboard Device
	Reference Designation: LAN
	Type: Ethernet
	Status: Enabled
	Bus Address: 0000:04:00.0
EOF

cat >"$tmp/lshw.json" <<'EOF'
{"class":"system","children":[
  {"class":"display","businfo":"pci@0000:01:00.0","product":"GeForce RTX 3060","vendor":"NVIDIA","size":268435456,"serial":"private-gpu-serial"},
  {"class":"display","businfo":"pci@0000:02:00.0","product":"AST2500","vendor":"ASPEED"},
  {"class":"network","businfo":"pci@0000:03:00.0","logicalname":"lan0","product":"RTL8125","vendor":"Realtek"},
  {"class":"network","businfo":"pci@0000:04:00.0","logicalname":"lan1","product":"I225-V","vendor":"Intel"}
]}
EOF

cat >"$tmp/lsblk.json" <<'EOF'
{"blockdevices":[
  {"path":"/dev/nvme0n1","type":"disk","tran":"nvme","size":"1000204886016","model":"Samsung SSD 980 PRO "},
  {"path":"/dev/nbd0","type":"disk","size":1024,"model":"Remote disk"},
  {"path":"/dev/loop0","type":"loop","size":1024},
  {"path":"/dev/sr0","type":"disk","size":1024,"model":"Optical"},
  {"path":"/dev/sda","type":"disk","tran":"sata","size":500107862016,"model":"Crucial MX500","children":[{"path":"/dev/sda1","type":"part","size":1024}]},
  {"path":"/dev/sda","type":"disk","tran":"sata","size":500107862016,"model":"Crucial MX500"}
]}
EOF
printf '%s\n' 'quiet mac=02:00:00:00:01:01 pxe_boot_mac=020000000202' >"$tmp/cmdline"
: >"$tmp/cpuinfo"
cat >"$tmp/bin/dmidecode" <<'EOF'
#!/usr/bin/env bash
cat "$HARDWARE_DMI"
EOF
cat >"$tmp/bin/lshw" <<'EOF'
#!/usr/bin/env bash
cat "$HARDWARE_LSHW"
EOF
cat >"$tmp/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
cat "$HARDWARE_LSBLK"
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HARDWARE_REQUEST.native"
task_http_test_decode_curl_args "$@"
printf '%s\n' "${task_http_test_curl_args[@]}" >"$HARDWARE_REQUEST"
exit 22
EOF
chmod +x "$tmp/bin/"*

export PATH="$tmp/bin:$PATH" HARDWARE_DMI="$tmp/dmi" HARDWARE_LSHW="$tmp/lshw.json" HARDWARE_LSBLK="$tmp/lsblk.json"
. "$overlay/usr/share/pxeos/lib/disk-health.sh"
. "$library"
rootpxe_collect_hardware_inventory "$tmp/sys" "$tmp/cpuinfo" "$tmp/cmdline" >"$tmp/report"

jq -e '
    .version == 1 and .pxeBootMac == "020000000202" and
    ([.devices[] | select(.kind == "cpu") | [.location, .model, .cores, .threads]] ==
      [["CPU0", "Intel Xeon Silver 4210", 10, 20], ["CPU1", "Intel Xeon Silver 4210", 8, 16]]) and
    ([.devices[] | select(.kind == "memory") | [.location, .model, .capacityBytes, .memoryType, .speedMTs]] ==
      [["DIMM A2", "KSM32RD4/32MEI", 34359738368, "DDR4", 3200], ["DIMM B2", "Other-DIMM", 17179869184, "DDR4", 2666]]) and
    ([.devices[] | select(.kind == "disk") | [.location, .model, .capacityBytes, .transport]] ==
      [["/dev/nvme0n1", "Samsung SSD 980 PRO", 1000204886016, "nvme"], ["/dev/sda", "Crucial MX500", 500107862016, "sata"]]) and
    ([.devices[] | select(.kind == "gpu") | [.model, .attachment, has("videoMemoryBytes")]] ==
      [["NVIDIA GeForce RTX 3060", "discrete", false], ["ASPEED AST2500", "integrated", false]]) and
    ([.devices[] | select(.kind == "nic") | [.model, .attachment, .mac, .linkMbps, has("pxe")]] ==
      [["Realtek RTL8125", "pcie", "020000000101", 2500, false], ["Intel I225-V", "onboard", "020000000202", 1000, false]])
' "$tmp/report" >/dev/null || fail 'multi-device report, order, metadata or boot MAC mismatch'
! grep -Fq 'private-' "$tmp/report" || fail 'device serial number leaked'

# Missing DMI still allows known Linux CPU topology, disks, GPUs and NICs.
mkdir -p "$tmp/sys/devices/system/cpu/"{cpu0,cpu1,cpu2}/topology
for cpu in 0 1 2; do
    printf '%s\n' 0 >"$tmp/sys/devices/system/cpu/cpu$cpu/topology/physical_package_id"
    printf '%s\n' "$((cpu / 2))" >"$tmp/sys/devices/system/cpu/cpu$cpu/topology/core_id"
done
printf '%s\n' 'model name : Example ARM CPU' >"$tmp/cpuinfo"
printf '%s\n' 'quiet mac=02:00:00:00:01:01' >"$tmp/legacy-cmdline"
HARDWARE_DMI=/dev/null rootpxe_collect_hardware_inventory "$tmp/sys" "$tmp/cpuinfo" "$tmp/legacy-cmdline" >"$tmp/partial"
jq -e '
    (has("pxeBootMac") | not) and
    ([.devices[] | select(.kind == "cpu") | [.model,.cores,.threads]] == [["Example ARM CPU",2,3]]) and
    ([.devices[] | select(.kind == "gpu") | has("attachment")] == [false,false]) and
    ([.devices[] | select(.kind == "nic") | .attachment] == ["pcie",null])
' "$tmp/partial" >/dev/null || fail 'fallback topology, unknown classification or legacy boot MAC'

printf '%s\n' 'pxe_boot_mac=bad pxe_boot_mac=020000000202' >"$tmp/ambiguous-cmdline"
rootpxe_collect_hardware_inventory "$tmp/sys" "$tmp/cpuinfo" "$tmp/ambiguous-cmdline" >"$tmp/ambiguous"
jq -e 'has("pxeBootMac") | not' "$tmp/ambiguous" >/dev/null || fail 'ambiguous boot parameter accepted'

jq 'del(.children[0].businfo, .children[2].product)' "$tmp/lshw.json" >"$tmp/lshw-incomplete.json"
jq 'del(.blockdevices[0].model)' "$tmp/lsblk.json" >"$tmp/lsblk-incomplete.json"
HARDWARE_LSHW="$tmp/lshw-incomplete.json" HARDWARE_LSBLK="$tmp/lsblk-incomplete.json" \
    rootpxe_collect_hardware_inventory "$tmp/sys" "$tmp/cpuinfo" "$tmp/cmdline" >"$tmp/incomplete"
jq -e '
    ([.devices[] | select(.kind == "disk") | [.location, .model]] == [["/dev/nvme0n1",null],["/dev/sda","Crucial MX500"]]) and
    ([.devices[] | select(.kind == "gpu") | [.model, .attachment]] == [["NVIDIA GeForce RTX 3060",null],["ASPEED AST2500","integrated"]]) and
    ([.devices[] | select(.kind == "nic") | [.mac, .model]] == [["020000000101",null],["020000000202","Intel I225-V"]])
' "$tmp/incomplete" >/dev/null || fail 'missing hardware facts dropped devices or changed order'

mkdir "$tmp/empty-sys"
if HARDWARE_DMI=/dev/null HARDWARE_LSHW=/dev/null HARDWARE_LSBLK=/dev/null \
    rootpxe_collect_hardware_inventory "$tmp/empty-sys" /dev/null "$tmp/legacy-cmdline" >"$tmp/empty"; then
    fail 'empty probes produced a report'
fi
[[ ! -s $tmp/empty ]] || fail 'empty probes produced output'

jq -n '{blockdevices:[range(129) | {type:"disk",path:("/dev/sd"+tostring),size:1}]}' >"$tmp/oversized"
if HARDWARE_LSBLK="$tmp/oversized" rootpxe_collect_hardware_inventory "$tmp/sys" "$tmp/cpuinfo" "$tmp/cmdline" >"$tmp/refused"; then
    fail 'device limit must refuse the report without truncating it'
fi
[[ ! -s $tmp/refused ]] || fail 'oversized inventory produced output'

# The reporter runs with the existing authenticated task context, sends the
# binding MAC separately from the measured PXE NIC, and isolates transport errors.
rootpxe_collect_hardware_inventory() { cat "$tmp/report"; }
rootpxe_require_task_context() { [[ $taskid == 7 && -n $task_token ]]; }
rootpxe_console_message() { printf '%s\n' "$*" >>"$tmp/console"; }
taskType=capture taskid=7 task_token=test-private-token mac=02:00:00:00:01:01
rootpxe_api='https://example.invalid/pxe/v1/'
export HARDWARE_REQUEST="$tmp/request"
rootpxe_send_hardware_inventory || fail 'upload failure changed task result'
grep -Fxq 'taskid=7' "$tmp/request" || fail 'missing task id'
grep -Fxq 'mac=02:00:00:00:01:01' "$tmp/request" || fail 'missing binding MAC'
grep -Fxq 'https://example.invalid/pxe/v1/inventory' "$tmp/request" || fail 'wrong inventory URL'
grep '^hardwareInventory=' "$tmp/request" | cut -d= -f2- | jq -e '.pxeBootMac == "020000000202"' >/dev/null
grep -Fxq "token=$task_token" "$tmp/request" || fail 'task token did not reach the authenticated request'
! grep -Fq "$task_token" "$tmp/request.native" || fail 'task token leaked to native argv'
! grep -Fq "$task_token" "$tmp/console" || fail 'task token leaked to console'

: >"$tmp/request"
taskType=inventory rootpxe_send_hardware_inventory
task_token='' rootpxe_send_hardware_inventory
[[ ! -s $tmp/request ]] || fail 'reported outside authenticated capture/deploy'
rootpxe_collect_hardware_inventory() { return 1; }
rootpxe_send_hardware_inventory || fail 'missing tools changed task result'
[[ ! -s $tmp/request ]] || fail 'empty/failed collector posted a report'

health_line=$(grep -n '^[[:space:]]*rootpxe_report_disk_health_after_checkin$' "$checkin" | cut -d: -f1)
hardware_line=$(grep -n '^[[:space:]]*rootpxe_send_hardware_inventory$' "$checkin" | cut -d: -f1)
[[ -n $health_line && -n $hardware_line && $health_line -lt $hardware_line ]] || fail 'hardware report bypasses the post-checkin disk gate'
printf 'PASS: PXEOS hardware inventory regression\n'
