def clean_text($limit):
  if type != "string" then null
  else
    gsub("[[:cntrl:]]"; " ") | gsub("^[[:space:]]+|[[:space:]]+$"; "") |
    if utf8bytelength > $limit or
       test("^(|unknown|none|not specified|not provided|not available|n/a|default string|to be filled by o[.]e[.]m[.])$"; "i")
    then null else . end
  end;

def positive_integer:
  (try tonumber catch null) |
  if type == "number" and . > 0 and . <= 9007199254740991 and floor == . then . else null end;

def dmi_records:
  split("\nHandle ")[] | split("\n") as $lines |
  ($lines[0] | capture("DMI type (?<type>[0-9]+),").type | tonumber) as $type |
  {type: $type, fields: (
    [$lines[1:][] | capture("^[\\t ]+(?<key>[^:]+):[\\t ]*(?<value>.*)$")] |
    map({key, value}) | from_entries
  )};

def dmi_cpus($records):
  [$records[] | select(.type == 4 and (.fields.Status // "" | startswith("Populated"))) |
   .fields as $cpu |
   ($cpu."Core Count" | positive_integer) as $cores |
   ($cpu."Core Enabled" | positive_integer) as $enabled_cores |
   {
     kind: "cpu",
     model: ($cpu.Version | clean_text(256)),
     location: ($cpu."Socket Designation" | clean_text(128)),
     cores: (if $cpu.Status | endswith("Disabled") then null else $enabled_cores // $cores end),
     threads: (
       if $cpu.Status | endswith("Disabled") then null
       else
         ($cpu."Thread Enabled" | positive_integer) //
         (if $enabled_cores == null or $enabled_cores == $cores then
            $cpu."Thread Count" | positive_integer
          else null end)
       end
     )
   }];

def cpu_topology($topology; $cpuinfo):
  [$cpuinfo | split("\n")[] |
   capture("^(?:model name|Processor|uarch)[\\t ]*:[\\t ]*(?<model>.+)$").model |
   clean_text(256) | select(. != null)] | unique as $models |
  [$topology | split("\n")[] | select(length > 0) | split("\t")] |
  group_by(.[0] | tonumber) |
  map({
    kind: "cpu",
    location: ("CPU " + .[0][0]),
    model: (if ($models | length) == 1 then $models[0] else null end),
    threads: length,
    cores: (if all(.[]; .[1] | test("^[0-9]+$")) then map(.[1]) | unique | length else null end)
  });

def dmi_size:
  [(strings | capture("^(?<value>[0-9]+)[ ]+(?<unit>[kmgt]i?B)$"; "i"))] |
  if length == 1 then
    .[0] |
    (.unit | ascii_downcase | sub("ib$"; "b")) as $unit |
    ((.value | tonumber) * ({"kb": 1024, "mb": 1048576, "gb": 1073741824, "tb": 1099511627776}[$unit])) | positive_integer
  else null end;

def dmi_memory($records):
  [$records[] | select(.type == 17) | .fields as $memory |
   ($memory.Size // "") as $size |
   ($memory."Part Number" | clean_text(256)) as $model |
   select(($size | test("^(no module installed|not installed|0 [kmgt]i?b)$"; "i") | not) and
          ($size != "" or $model != null)) |
   {
     kind: "memory",
     model: $model,
     location: ($memory.Locator | clean_text(128)),
     capacityBytes: ($size | dmi_size),
     memoryType: ($memory.Type | clean_text(32)),
     speedMTs: (
       [$memory."Configured Memory Speed", $memory.Speed |
        strings | capture("^(?<speed>[0-9]+)[ ]+MT/s$"; "i").speed |
        positive_integer | select(. != null)][0]
     )
   }];

def pci_address:
  if type == "string" and test("^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}[.][0-7]$"; "i")
  then ascii_downcase else null end;

def hardware_attachment($address; $kind; $records; $slots; $paths):
  if $address == null then null
  elif any($records[];
    .type == 41 and (.fields."Bus Address" | pci_address) == $address and
    (.fields.Status // "Enabled" | startswith("Enabled")) and
    .fields.Type == (if $kind == "nic" then "Ethernet" else "Video" end)
  ) then if $kind == "nic" then "onboard" else "integrated" end
  else
    # A physical slot may describe the upstream port instead of the endpoint.
    ([$address] + ($paths[$address] // [])) as $addresses |
    if any($records[];
      .type == 9 and
      ((.fields."Bus Address" | pci_address) as $slot | ($addresses | index($slot)) != null) and
      (.fields."Current Usage" // "In Use") == "In Use" and
      ([.fields.Type, .fields.Designation] | any(.[] | strings; test("PCIe|PCI Express"; "i")))
    ) or any($addresses[]; .[0:-2] as $slot | ($slots | index($slot)) != null)
    then if $kind == "nic" then "pcie" else "discrete" end
    else null end
  end;

def hardware_model:
  (.product | clean_text(256)) as $product | (.vendor | clean_text(128)) as $vendor |
  if $product == null then null
  elif $vendor == null or ($product | ascii_downcase | startswith($vendor | ascii_downcase)) then $product
  else ($vendor + " " + $product | clean_text(256)) // $product end;

def hardware_gpus($hardware; $records; $slots; $paths):
  [$hardware[] | select(.class == "display") |
   ((.businfo | strings | sub("^pci@"; "") | pci_address) // null) as $address |
   {
     kind: "gpu",
     model: hardware_model,
     attachment: hardware_attachment($address; "gpu"; $records; $slots; $paths)
   }];

def hardware_nics($interfaces; $hardware; $records; $slots; $paths):
  [$interfaces | split("\n")[] | select(length > 0) | split("\t") as [$name, $device, $mac, $speed] |
   ($device | pci_address) as $address |
   [$hardware[] | select(.class == "network")] as $candidates |
   ([$candidates[] | select([.logicalname | if type == "array" then .[] else . end] | index($name) != null)][0] //
    [$candidates[] | select($address != null and (.businfo | strings | sub("^pci@"; "") | pci_address) == $address)][0]) as $match |
   {
     kind: "nic",
     model: ($match | hardware_model),
     attachment: hardware_attachment($address; "nic"; $records; $slots; $paths),
     linkMbps: ($speed | positive_integer),
     mac: $mac
   }];

def hardware_disks($disks):
  reduce $disks[] as $disk ({seen: {}, devices: []};
    if .seen[$disk.path] then .
    else .seen[$disk.path] = true | .devices += [{
      kind: "disk",
      model: ($disk.model | clean_text(256)),
      location: ($disk.path | clean_text(128)),
      capacityBytes: ($disk.size | positive_integer),
      transport: ($disk.tran | clean_text(32))
    }]
    end
  ) | .devices;

[$dmi | dmi_records] as $records |
[(try ($hardware | fromjson) catch []) | .. | objects | select(has("class"))] as $hardware_devices |
($slots | split("\n") | map(ascii_downcase)) as $slot_addresses |
([$pci_paths | split("\n")[] | select(length > 0) | split("\t") |
  {key: .[0], value: .[1:]}] | from_entries) as $device_paths |
dmi_cpus($records) as $processors |
{
  version: 1,
  devices: (
    (if ($processors | length) > 0 then $processors else cpu_topology($topology; $cpuinfo) end) +
    dmi_memory($records) + hardware_disks($disks) + hardware_gpus($hardware_devices; $records; $slot_addresses; $device_paths) +
    hardware_nics($interfaces; $hardware_devices; $records; $slot_addresses; $device_paths) |
    map(with_entries(select(.value != null)))
  )
} |
if $boot_mac != "" then .pxeBootMac = $boot_mac else . end |
select((.devices | length) > 0 and (.devices | length) <= 128 and (tojson | utf8bytelength) <= 65536)
