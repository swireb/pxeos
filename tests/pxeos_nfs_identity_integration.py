#!/usr/bin/env python3
"""Ephemeral NFSv4.2 fixture for client owner collisions on isolated QEMU guests."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import time

VERSION = "7.0.0-43-generic"
SOURCE = Path(__file__).resolve().parents[1] / "Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib"
HOSTS = ("192.0.2.2", "198.51.100.2")
MACS = ("025058450001", "025058450002")
CGROUP = Path("/sys/fs/cgroup" + Path("/proc/self/cgroup").read_text().strip().split(":", 2)[2])
SLICE = CGROUP.parent
PAYLOAD = bytes(range(256)) * 1024
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()
RATE_FILE_SIZE = 16 * 1024 * 1024
RATE_SECONDS = 60

GUEST_INIT = r"""#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/usr/sbin
mount -t devtmpfs none /dev
mount -t proc none /proc
mount -t sysfs none /sys
hostname pxeos
ip link set lo up
read -r console role phase index clients measurement _ < /proc/cmdline
address() {
    ip addr add "$2/24" dev "$1"
    ip link set "$1" up
}
rpc_sample() {
    awk -v label="$1" '$1=="EXCHANGE_ID:" || $1=="CREATE_SESSION:" || $1=="DESTROY_SESSION:" || $1=="READ:" {print label,$0}' /proc/self/mountstats
}
if [[ $role == server ]]; then
    . /fixture/nfsd
    address eth0 192.0.2.1
    if [[ $measurement == throughput ]]; then
        read -r mtu </sys/class/net/eth0/mtu
        [[ $mtu == 1500 ]]
        printf 'SERVER_MTU %s\n' "$mtu"
    fi
    if [[ $clients == 2 ]]; then address eth1 198.51.100.1; fi
    mount -t tmpfs none /export
    cp /fixture/payload.bin /export/payload
    chmod 644 /export/payload
    mount -t nfsd none /proc/fs/nfsd
    if [[ $measurement == throughput ]]; then
        printf '1048576\n' >/proc/fs/nfsd/max_block_size
        read -r block_size </proc/fs/nfsd/max_block_size
        [[ $block_size == 1048576 ]]
        printf 'SERVER_MAX_BLOCK_SIZE %s\n' "$block_size"
    fi
    mount -t rpc_pipefs none /var/lib/nfs/rpc_pipefs
    rpcbind -f &
    rpc.mountd -F &
    nfsdcld -F &
    exportfs -ra
    rpc.nfsd 4
    printf 'SERVER_READY\n'
    for i in $(seq 1 300); do
        printf 'SERVER_SAMPLE %s\n' "$i"
        for info in /proc/fs/nfsd/clients/*/info; do
            [[ -f $info ]] || continue
            addr= owner= state= id=
            while IFS= read -r line; do
                case $line in
                    'address: '*) addr=${line#address: } ;;
                    'name: '*) owner=${line#name: } ;;
                    'status: '*) state=${line#status: } ;;
                    'clientid: '*) id=${line#clientid: } ;;
                esac
            done 2>/dev/null <"$info" || :
            if [[ -n $addr && -n $owner && -n $state && -n $id ]]; then
                printf 'OWNER|%s|%s|%s|%s\n' "$addr" "$owner" "$state" "$id"
            fi
        done
        if [[ $measurement == throughput ]]; then
            read -r stamp _ </proc/uptime
            awk -v sample="$i" -v stamp="$stamp" '
                $1 == "cpu" {for (j=2;j<=9;j++) total+=$j; idle=$5+$6}
                $1 == "io" {bytes=$2}
                $1 == "proc4ops" {reads=$28}
                END {printf "SERVER_RATE %s %s %.0f %.0f %s %s\n",sample,stamp,total,idle,bytes,reads}
            ' /proc/stat /proc/net/rpc/nfsd
        fi
        printf 'SERVER_SAMPLE_END %s\n' "$i"
        sleep 1
    done
elif [[ $role == runner ]]; then
    . /fixture/nfsv4
    exec /bin/bash /fixture/group "$phase" "$measurement"
else
    . /fixture/nfsv4
    if [[ $index == 1 ]]; then
        address eth0 192.0.2.2
        server=192.0.2.1
        mac=025058450001
    else
        address eth0 198.51.100.2
        server=198.51.100.1
        mac=025058450002
    fi
    if [[ $phase == fixed ]]; then
        . /fixture/normalize.sh
        . /fixture/storage-io.sh
        rootpxe_storage_init_nfs_identity 4.2
    fi
    printf 'CLIENT_MOUNTING %s ' "$index"
    cat /sys/fs/nfs/net/nfs_client/identifier
    mount -i -t nfs4 -o "ro,addr=$server,vers=4.2,proto=tcp" "$server:/" /mnt
    printf 'CLIENT_MOUNTED %s\n' "$index"
    for i in $(seq 1 35); do
        result=$(dd if=/mnt/payload iflag=direct bs=64K status=none | sha256sum)
        [[ $result == "$(cat /fixture/digest)  -" ]]
        printf 'CLIENT_READ %s %s\n' "$index" "$i"
        if [[ $i == 1 ]]; then rpc_sample RPC_BASE; fi
        sleep 1
    done
    rpc_sample RPC_END
    printf 'CLIENT_DONE %s\n' "$index"
fi
while :; do sleep 1; done
"""


GROUP_CLIENTS = 50
GROUP_HOSTS = tuple(f"192.0.2.{index + 10}" for index in range(1, GROUP_CLIENTS + 1))
GROUP_MACS = tuple(f"02505846{index:04x}" for index in range(1, GROUP_CLIENTS + 1))
GROUP_ROUNDS = 18

GUEST_GROUP = r"""#!/bin/bash
set -euo pipefail
. /fixture/bridge
. /fixture/veth
ip link add testbridge type bridge
ip link set eth0 master testbridge
ip link set eth0 up
ip link set testbridge up
mkdir -p /run/clients
outer_net=$(readlink /proc/self/ns/net)
outer_mnt=$(readlink /proc/self/ns/mnt)
for i in $(seq 1 50); do
    name=client$i
    address=192.0.2.$((i + 10))
    printf -v mac '02505846%04x' "$i"
    printf -v ethernet '%s:%s:%s:%s:%s:%s' "${mac:0:2}" "${mac:2:2}" "${mac:4:2}" "${mac:6:2}" "${mac:8:2}" "${mac:10:2}"
    ip netns add "$name"
    ip link add "veth$i" type veth peer name "peer$i"
    ip link set "veth$i" master testbridge
    ip link set "veth$i" up
    ip link set "peer$i" netns "$name"
    ip -n "$name" link set "peer$i" name eth0
    ip -n "$name" link set eth0 address "$ethernet"
    ip -n "$name" addr add "$address/24" dev eth0
    ip -n "$name" link set eth0 up
    ip -n "$name" link set lo up
    ip netns exec "$name" /bin/bash /fixture/group-client "$1" "$i" "$address" "$mac" "$outer_net" "$outer_mnt" "$2" \
        >"/run/clients/$i.log" 2>&1 &
done
for _ in $(seq 1 120); do
    ready=(/run/clients/*.ready)
    if [[ ${#ready[@]} -eq 50 ]]; then break; fi
    sleep 0.25
done
if [[ ${#ready[@]} -ne 50 ]]; then
    printf 'GROUP_SETUP_FAILED %s\n' "${#ready[@]}"
    cat /run/clients/*.log
    exit 1
fi
read -r stamp _ </proc/uptime
printf 'GROUP_MOUNT_WINDOW %s\n' "$stamp"
: >/run/clients/mount-go
sleep 20
read -r stamp _ </proc/uptime
printf 'GROUP_READ_WINDOW %s\n' "$stamp"
if [[ $2 == throughput ]]; then
    now=$(/fixture/nfs-rate-reader --clock)
    start=$((now + 7000000000))
    end=$((start + 60000000000))
    printf '%s %s\n' "$start" "$end" >/run/clients/rate-window
    : >/run/clients/read-go
    /fixture/nfs-rate-reader --wait "$start"
    printf 'RATE_WINDOW_START %s %s\n' "$start" "$end"
    awk '$1 == "cpu" {for (i=2;i<=9;i++) total+=$i; print "RUNNER_CPU_START",total,$5+$6; exit}' /proc/stat
    /fixture/nfs-rate-reader --wait "$end"
    printf 'RATE_WINDOW_END\n'
    awk '$1 == "cpu" {for (i=2;i<=9;i++) total+=$i; print "RUNNER_CPU_END",total,$5+$6; exit}' /proc/stat
else
    : >/run/clients/read-go
    sleep 115
fi
read -r stamp _ </proc/uptime
printf 'GROUP_DEADLINE %s\n' "$stamp"
for i in $(seq 1 50); do
    read -r pid </run/clients/"$i".ready
    awk -v i="$i" '$1 == "rpc" {print "RPC_NET", i, $0}' "/proc/$pid/net/rpc/nfs" 2>/dev/null || :
    awk -v i="$i" '$1=="EXCHANGE_ID:" || $1=="CREATE_SESSION:" || $1=="DESTROY_SESSION:" || $1=="READ:" {print "RPC_DEADLINE", i, $0}' \
        "/proc/$pid/mountstats" 2>/dev/null || :
    if [[ $2 == throughput ]]; then
        awk -v client="$i" '
            $1 == "RATE_PROGRESS" {if (NF == 5) progress = $0; next}
            $1 ~ /^RATE_SAMPLE_/ {print $1,client,$2; next}
            {print}
            END {if (progress != "") print "RATE_FINAL",client,substr(progress,15)}
        ' "/run/clients/$i.log"
    else
        cat "/run/clients/$i.log"
    fi
done
printf 'GROUP_DONE\n'
while :; do sleep 1; done
"""

GUEST_GROUP_CLIENT = r"""#!/bin/bash
set -euo pipefail
phase=$1 i=$2 address=$3 mac=$4 measurement=$7
net=$(readlink /proc/self/ns/net)
mnt=$(readlink /proc/self/ns/mnt)
[[ $net != "$5" && $mnt != "$6" ]]
mount --make-rprivate /
# ip netns exec has already mounted the worker's own sysfs view.
read -r visible_mac </sys/class/net/eth0/address
[[ ${visible_mac//:/} == "$mac" ]]
if [[ $measurement == throughput ]]; then
    read -r mtu </sys/class/net/eth0/mtu
    [[ $mtu == 1500 ]]
fi
if [[ $phase == fixed ]]; then
    . /fixture/normalize.sh
    . /fixture/storage-io.sh
    rootpxe_storage_init_nfs_identity 4.2
fi
identifier=$(cat /sys/fs/nfs/net/nfs_client/identifier)
printf 'WORKER_READY %s %s %s %s %s %s\n' "$i" "$net" "$mnt" "$address" "$mac" "$identifier"
printf '%s\n' "$$" >"/run/clients/$i.ready"
while [[ ! -f /run/clients/mount-go ]]; do sleep 1; done

event() {
    local stamp
    read -r stamp _ </proc/uptime
    printf '%s %s %s%s\n' "$1" "$i" "$stamp" "${2:+ $2}"
}

rpc_sample() {
    awk -v label="$1" -v i="$i" '$1=="EXCHANGE_ID:" || $1=="CREATE_SESSION:" || $1=="DESTROY_SESSION:" || $1=="READ:" {print label,i,$0}' /proc/self/mountstats
}

read_image() {
    local round stamp result checksum
    checksum=$(cat /fixture/digest)
    for round in $(seq 1 18); do
        if result=$(dd if=/mnt/payload iflag=direct bs=64K status=none | sha256sum); then
            :
        else
            event READ_ERROR "$?"
            return 0
        fi
        if [[ $result != "$checksum  -" ]]; then
            event READ_HASH_ERROR
            return 0
        fi
        read -r stamp _ </proc/uptime
        printf 'READ_OK %s %s %s 262144 %s\n' "$i" "$round" "$stamp" "$checksum"
        if [[ $round == 1 ]]; then rpc_sample RPC_BASE; fi
        if [[ $round != 18 ]]; then sleep 2; fi
    done
    rpc_sample RPC_END
    event READ_DONE
}

event MOUNT_BEGIN
options=ro,addr=192.0.2.1,vers=4.2,proto=tcp
if [[ $measurement == throughput ]]; then options+=,rsize=1048576; fi
if mount -i -t nfs4 -o "$options" 192.0.2.1:/ /mnt; then
    event MOUNT_OK
    if [[ -f /run/clients/read-go ]]; then
        event MOUNT_LATE
    else
        while [[ ! -f /run/clients/read-go ]]; do sleep 1; done
    fi
    event READ_BEGIN
    if [[ $measurement == throughput ]]; then
        awk -v i="$i" '/^device / {n=($0 ~ / mounted on \/mnt with fstype nfs4/)} n && $1=="opts:" {print "RATE_MOUNT",i,$2; exit}' /proc/self/mountstats
        rpc_sample RPC_BASE
        read -r start end </run/clients/rate-window
        if /fixture/nfs-rate-reader --read "$start" "$end"; then
            event READ_DONE
        else
            event READ_ERROR "$?"
        fi
    else
        read_image
    fi
else
    event MOUNT_ERROR "$?"
fi
while :; do sleep 1; done
"""


def copy_file(source, root, target):
    path = root / target.lstrip("/")
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, path)


def copy_binary(source, root, target):
    copy_file(source, root, target)
    links = subprocess.check_output(["ldd", source], text=True)
    if "not found" in links:
        raise RuntimeError(f"Missing dependency for {source}: {links}")
    for library in re.findall(r"(/[^\s()]+)\s+\(", links):
        copy_file(library, root, library)


def make_fixture(work, kernel_deb, server_deb, clients, throughput=False):
    packages = work / "deb"
    packages.mkdir()
    for source, expected in (
        (kernel_deb, "fb44ae94b483fb2e04aa898b92863552bea8a92a6ea9b5f4610a7bd17ac5d4a1"),
        (server_deb, "8a0c35c9afae663ec9e7963edd946204129c74404502c65bd45835344d9e590f"),
    ):
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"SHA256 mismatch: {source}")
        subprocess.run(["dpkg-deb", "--extract", source, packages], check=True, timeout=20)

    root = work / "guest"
    for name in ("usr/bin", "usr/sbin", "usr/lib", "usr/lib64", "dev", "proc", "sys", "var/lib/nfs/rpc_pipefs",
                 "var/lib/nfs/v4recovery", "var/run", "run", "mnt", "export", "etc", "fixture"):
        (root / name).mkdir(parents=True, exist_ok=True)
    for name in ("bin", "sbin", "lib", "lib64"):
        (root / name).symlink_to(f"usr/{name}")

    tools = ("/usr/bin/bash", "/usr/bin/awk", "/usr/bin/dd", "/usr/bin/mount", "/usr/bin/ip",
             "/usr/sbin/insmod", "/usr/sbin/rpcbind")
    for tool in tools:
        copy_binary(tool, root, tool)
    copy_file("/usr/bin/busybox", root, "/usr/bin/busybox")
    for applet in ("sh", "cat", "chmod", "cp", "hostname", "mkdir", "readlink", "seq", "sha256sum", "sleep"):
        (root / "usr/bin" / applet).symlink_to("busybox")
    for name in ("exportfs", "rpc.mountd", "rpc.nfsd", "nfsdcld"):
        tool = next((p for p in packages.rglob(name) if p.is_file() and p.stat().st_mode & 0o111), None)
        if tool is None:
            raise RuntimeError(f"NFS server package lacks {name}")
        copy_binary(tool, root, f"/usr/sbin/{name}")

    modules = ("nfsd", "nfsv4") if clients == 2 else ("nfsd", "nfsv4", "bridge", "veth")
    for module in modules:
        dependencies = subprocess.check_output(["modprobe", "--show-depends", "-S", VERSION, module], text=True)
        script = []
        for line in dependencies.splitlines():
            command, location, *_ = line.split()
            if command != "insmod":
                raise RuntimeError(f"Unexpected module dependency: {line}")
            name = Path(location).name.removesuffix(".zst")
            file = root / "fixture" / name
            if not file.exists():
                with file.open("wb") as target:
                    subprocess.run(["zstd", "-d", "-c", location], stdout=target, check=True, timeout=10)
            script.append(f"insmod /fixture/{name}")
        (root / "fixture" / module).write_text("\n".join(script) + "\n")

    (root / "etc/exports").write_text(
        "/export 192.0.2.0/24(ro,fsid=0,no_subtree_check,sync,insecure)"
        " 198.51.100.0/24(ro,fsid=0,no_subtree_check,sync,insecure)\n")
    (root / "etc/passwd").write_text("root:x:0:0:root:/:/bin/sh\n_rpc:x:109:65534::/:/bin/sh\nnobody:x:65534:65534::/:/bin/sh\n")
    (root / "etc/group").write_text("root:x:0:\nnogroup:x:65534:\n")
    (root / "etc/nsswitch.conf").write_text("passwd: files\ngroup: files\nhosts: files\nservices: files\n")
    (root / "etc/services").write_text("sunrpc 111/tcp portmapper\nsunrpc 111/udp portmapper\nnfs 2049/tcp\nnfs 2049/udp\n")
    (root / "etc/netconfig").write_text("udp tpi_clts v inet udp - -\ntcp tpi_cots_ord v inet tcp - -\nlocal tpi_cots_ord - loopback - - -\n")
    payload = PAYLOAD * (RATE_FILE_SIZE // len(PAYLOAD)) if throughput else PAYLOAD
    (root / "fixture/payload.bin").write_bytes(payload)
    (root / "fixture/digest").write_text(DIGEST + "\n")
    (root / "fixture/normalize.sh").write_text(re.search(
        r"^rootpxe_normalize_mac\(\) \{.*?^\}", (SOURCE / "funcs.sh").read_text(), re.M | re.S).group() + "\n")
    copy_file(SOURCE / "storage-io.sh", root, "/fixture/storage-io.sh")
    if clients == GROUP_CLIENTS:
        (root / "fixture/group").write_text(GUEST_GROUP)
        (root / "fixture/group-client").write_text(GUEST_GROUP_CLIENT)
    if throughput:
        reader = work / "nfs-rate-reader"
        source = Path(__file__).with_name("pxeos_nfs_rate_reader.c")
        subprocess.run(["cc", "-std=c17", "-O2", "-Wall", "-Wextra", "-Werror", source, "-o", reader],
                       check=True, timeout=20)
        copy_binary(reader, root, "/fixture/nfs-rate-reader")
    init = root / "init"
    init.write_text(GUEST_INIT)
    init.chmod(0o755)
    archive = work / "guest.cpio"
    names = "".join(f"{name.relative_to(root)}\n" for name in sorted(root.rglob("*")))
    with archive.open("wb") as output:
        subprocess.run(["cpio", "-o", "-H", "newc", "--owner=0:0", "--quiet"], cwd=root, input=names,
                       text=True, stdout=output, check=True, timeout=20)
    return packages / "boot" / f"vmlinuz-{VERSION}", archive


def start_vm(work, processes, qemu, kernel, archive, phase, role, index, connections, clients=2,
             measurement="identity", label=None):
    options = []
    for slot, (link, mac) in enumerate(connections):
        if measurement == "throughput":
            network = f"dgram,id=net{slot},local.type=fd,local.str={link.fileno()}"
        else:
            network = f"socket,id=net{slot},fd={link.fileno()}"
        options.extend(("-netdev", network,
                        "-device", f"virtio-net-pci,netdev=net{slot},mac={mac},romfile="))
    log = work / f"{label or phase}-{role}{index}.log"
    memory = "1536" if role == "runner" else "768"
    cpus = "2" if clients == GROUP_CLIENTS else "1"
    kernel_options = " kho=off" if measurement == "throughput" else ""
    with log.open("wb") as output:
        processes.append(subprocess.Popen(
            [str(qemu / "usr/bin/qemu-system-x86_64"), "-L", str(qemu / "usr/share/qemu"),
             "-bios", str(qemu / "usr/share/seabios/bios-256k.bin"), "-machine", "q35,accel=tcg",
             "-cpu", "max", "-smp", cpus, "-m", memory, "-nodefaults", "-display", "none",
             "-serial", "stdio", "-monitor", "none", "-no-reboot", "-no-shutdown",
             "-kernel", str(kernel), "-initrd", str(archive),
             "-append", f"console=ttyS0 {role} {phase} {index} {clients} {measurement} net.ifnames=0 panic=0{kernel_options}", *options],
            stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            env={"PATH": "/usr/bin", "LD_LIBRARY_PATH": str(qemu / "usr/lib/x86_64-linux-gnu")},
            pass_fds=tuple(link.fileno() for link, _ in connections)))
    return log


def lines(log):
    return log.read_text(errors="replace")


def limit_events():
    watched = {"max", "fail", "oom", "oom_kill", "oom_group_kill"}
    return {(name, key): int(value)
            for name in ("memory.events", "memory.swap.events")
            for key, value in (line.split() for line in (SLICE / name).read_text().splitlines())
            if key in watched}


def poll(processes, condition, timeout, initial_events):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if limit_events() != initial_events:
            raise RuntimeError("Shared cgroup reached a memory or swap limit")
        if any(process.poll() is not None for process in processes):
            raise RuntimeError("A QEMU guest exited before fixture completion")
        if condition():
            return True
        time.sleep(0.20)
    return False


def client_reads(log, index):
    return len(re.findall(rf"^CLIENT_READ {index} \d+$", lines(log), re.M))


def read_owners(log, complete=False):
    samples = []
    for sample in lines(log).split("SERVER_SAMPLE ")[1:]:
        if complete and not re.search(r"^SERVER_SAMPLE_END \d+$", sample, re.M):
            continue
        rows = re.findall(r'^OWNER\|"([^"]+):\d+"\|"([^"]+)"\|(\w+)\|(0x[0-9a-f]+)$', sample, re.M)
        samples.append(rows)
    return samples


def stop_vms(processes):
    for process in processes:
        if process.poll() is None:
            process.terminate()
    for process in processes:
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def run_phase(work, qemu, kernel, archive, phase, initial_events):
    processes = []
    links = [socket.socketpair(), socket.socketpair()]
    try:
        server = start_vm(work, processes, qemu, kernel, archive, phase, "server", 0,
                          [(links[0][0], "02:50:58:45:00:11"), (links[1][0], "02:50:58:45:00:12")])
        if not poll(processes, lambda: "SERVER_READY" in lines(server), 45, initial_events):
            raise RuntimeError(f"Server failed to reach ready state: {server}")
        clients = [
            start_vm(work, processes, qemu, kernel, archive, phase, "client", i + 1,
                     [(pair[1], ":".join(MACS[i][j:j+2] for j in range(0, 12, 2)))])
            for i, pair in enumerate(links)
        ]
        for pair in links:
            for link in pair:
                link.close()
        if not poll(processes, lambda: all("CLIENT_MOUNTING " in lines(log) for log in clients), 30, initial_events):
            raise RuntimeError("Both client kernels did not reach mount")
        if phase == "baseline":
            initial_samples = len(read_owners(server))
            if not poll(processes, lambda: len(read_owners(server)) >= initial_samples + 15, 25, initial_events):
                raise RuntimeError("Missing baseline server observation window")
            observed = [row for sample in read_owners(server) for row in sample if row[1] == "Linux NFSv4.2 pxeos"]
            ids = {host: {row[3] for row in observed if row[0] == host} for host in HOSTS}
            if not all(ids.values()) or not any(len(values) >= 2 for values in ids.values()):
                raise RuntimeError(f"Did not reproduce a shared owner with changing client IDs: {ids}")
            print(f"BASELINE owner=Linux NFSv4.2 pxeos client_id_counts={[len(x) for x in ids.values()]}", flush=True)
            return
        overlap = []

        def fixed_done():
            if all(0 < client_reads(log, i + 1) < 35 for i, log in enumerate(clients)):
                overlap.append(time.monotonic())
            return all("CLIENT_DONE " in lines(log) for log in clients)

        if not poll(processes, fixed_done, 60, initial_events):
            raise RuntimeError(f"Fixed dual client reads incomplete: {[client_reads(log, i+1) for i, log in enumerate(clients)]}")
        overlap_seconds = overlap[-1] - overlap[0] if overlap else 0
        if overlap_seconds < 30:
            raise RuntimeError(f"Expected at least 30 seconds of overlapping reads: {overlap_seconds:.2f}")
        confirmed = []
        for sample in read_owners(server):
            by_addr = {row[0]: (row[1], row[3]) for row in sample if row[2] == "confirmed"}
            if all(host in by_addr and f"rootpxe-{mac}" in by_addr[host][0] for host, mac in zip(HOSTS, MACS)):
                confirmed.append(tuple(by_addr[host] for host in HOSTS))
        if len(confirmed) < 31 or len(set(confirmed)) != 1:
            raise RuntimeError(f"Expected at least 31 dual-confirmed samples and stable client IDs: {len(confirmed)} samples")
        for i, log in enumerate(clients):
            counts = {"BASE": {}, "END": {}}
            for label, operation, values in re.findall(r'^RPC_(BASE|END)\s+([A-Z_]+):\s+([0-9 ][0-9 ]+)$', lines(log), re.M):
                counts[label][operation] = tuple(map(int, values.split()))
            before, after = counts["BASE"], counts["END"]
            if (client_reads(log, i + 1) != 35 or before["EXCHANGE_ID"][0] < 1 or after["CREATE_SESSION"][0] != 1
                    or after["DESTROY_SESSION"][0] != 0
                    or any(after[op][0] != before[op][0] for op in ("EXCHANGE_ID", "CREATE_SESSION", "DESTROY_SESSION"))):
                raise RuntimeError(f"Client {i+1} did not sustain a single NFS session: {counts}")
            if (any(values[0] != values[1] or values[2] or values[-1] for values in after.values())
                    or after["READ"][0] - before["READ"][0] < 34):
                raise RuntimeError(f"Client {i+1} had RPC errors, timeouts, or no NFS reads: {counts}")
            print(f"FIXED client={i+1} verified=35 bytes_per_read={len(PAYLOAD)} sha256={DIGEST} rpc={counts}", flush=True)
        print(f"FIXED overlap_seconds={overlap_seconds:.2f} dual_confirmed_samples={len(confirmed)} owner_and_client_id={confirmed[0]}", flush=True)
    finally:
        for pair in links:
            for link in pair:
                link.close()
        stop_vms(processes)


def group_records(log, phase):
    raw = lines(log)
    deadline = float(re.search(r"^GROUP_DEADLINE ([\d.]+)$", raw, re.M)[1])
    mount_release = float(re.search(r"^GROUP_MOUNT_WINDOW ([\d.]+)$", raw, re.M)[1])
    mount_cutoff = float(re.search(r"^GROUP_READ_WINDOW ([\d.]+)$", raw, re.M)[1])
    ready_rows = re.findall(r"^WORKER_READY (\d+) (net:\[\d+\]) (mnt:\[\d+\]) (\S+) (\S+) (\S+)$", raw, re.M)
    workers = {
        int(i): {"netns": net, "mountns": mnt, "address": addr, "mac": mac, "identifier": identifier,
                 "events": {}, "reads": [], "rpc": {}}
        for i, net, mnt, addr, mac, identifier in ready_rows
    }
    if len(ready_rows) != GROUP_CLIENTS or set(workers) != set(range(1, GROUP_CLIENTS + 1)):
        raise RuntimeError(f"Expected {GROUP_CLIENTS} independent workers: {log}")
    if any(len({worker[key] for worker in workers.values()}) != GROUP_CLIENTS
           for key in ("netns", "mountns", "address", "mac")):
        raise RuntimeError(f"Worker namespace or address was shared: {log}")
    for i, (address, mac) in enumerate(zip(GROUP_HOSTS, GROUP_MACS), 1):
        expected = "(null)" if phase == "baseline" else f"rootpxe-{mac}"
        if (workers[i]["address"], workers[i]["mac"], workers[i]["identifier"]) != (address, mac, expected):
            raise RuntimeError(f"Worker {i} observed the wrong network or NFS identifier: {workers[i]}")

    for kind, i, stamp, code in re.findall(
            r"^(MOUNT_BEGIN|MOUNT_OK|MOUNT_ERROR|MOUNT_LATE|READ_BEGIN|READ_ERROR|READ_HASH_ERROR|READ_DONE) "
            r"(\d+) ([\d.]+)(?: (\d+))?$", raw, re.M):
        if float(stamp) <= deadline:
            workers[int(i)]["events"][kind] = {"time": float(stamp), "exit": int(code) if code else None}
    for i, iteration, stamp, size, digest in re.findall(
            r"^READ_OK (\d+) (\d+) ([\d.]+) (\d+) ([0-9a-f]{64})$", raw, re.M):
        if float(stamp) <= deadline:
            workers[int(i)]["reads"].append((int(iteration), float(stamp), int(size), digest))
    for label, i, op, counts in re.findall(
            r"^RPC_(BASE|END|DEADLINE) (\d+)\s+([A-Z_]+):\s+([0-9 ][0-9 ]+)$", raw, re.M):
        workers[int(i)]["rpc"].setdefault(label, {})[op] = tuple(map(int, counts.split()))
    for i, calls, retrans, auth_refresh in re.findall(r"^RPC_NET (\d+) rpc (\d+) (\d+) (\d+)$", raw, re.M):
        workers[int(i)]["rpc_network"] = {"calls": int(calls), "retrans": int(retrans), "auth_refresh": int(auth_refresh)}

    for i, worker in workers.items():
        events, reads = worker["events"], worker["reads"]
        if not mount_release <= events.get("MOUNT_BEGIN", {}).get("time", -1) <= mount_cutoff:
            raise RuntimeError(f"Worker {i} did not enter the common mount window: {log}")
        if not worker.get("rpc_network", {}).get("calls"):
            raise RuntimeError(f"Worker {i} issued no observed NFS RPC: {log}")
        if "MOUNT_OK" in events:
            if "READ_DONE" in events:
                state = "read_complete"
            elif "READ_HASH_ERROR" in events or "READ_ERROR" in events:
                state = "read_error"
            else:
                state = "read_blocked"
        elif "MOUNT_ERROR" in events:
            state = "mount_error"
        else:
            state = "mount_blocked"
        worker["result"] = state
        worker["mount_late"] = "MOUNT_LATE" in events
        worker["first_read"] = reads[0][1] if reads else None
        worker["last_read"] = reads[-1][1] if reads else None
        worker["verified_bytes"] = sum(row[2] for row in reads)
        if any(size != len(PAYLOAD) or digest != DIGEST for _, _, size, digest in reads):
            raise RuntimeError(f"Worker {i} reported an invalid hash or size: {log}")
    return workers


def check_group_fixed(workers):
    for i, worker in workers.items():
        reads = worker["reads"]
        if (worker["result"] != "read_complete" or [row[0] for row in reads] != list(range(1, GROUP_ROUNDS + 1))
                or worker["last_read"] - worker["first_read"] < 30):
            raise RuntimeError(f"Worker {i} did not complete {GROUP_ROUNDS} checked rounds over 30 seconds: {worker}")
        before = worker["rpc"]["BASE"]
        final = worker["rpc"]["END"]
        deadline = worker["rpc"]["DEADLINE"]
        if (before["CREATE_SESSION"][0] != 1 or before["DESTROY_SESSION"][0] != 0
                or any(before[op][0] != deadline[op][0] for op in ("EXCHANGE_ID", "CREATE_SESSION", "DESTROY_SESSION"))
                or final["READ"][0] - before["READ"][0] < GROUP_ROUNDS - 1):
            raise RuntimeError(f"Worker {i} did not keep one stable session: {worker['rpc']}")
        if (worker["rpc_network"]["retrans"]
                or any(counts[0] != counts[1] or counts[2] or counts[-1] for counts in deadline.values())):
            raise RuntimeError(f"Worker {i} had an RPC retransmission, timeout, or error: {worker['rpc']}")


def rate_distribution(values):
    if not values:
        return None
    return {"min": min(values), "median": statistics.median(values), "max": max(values)}


def cpu_busy(start, end):
    ticks = end[0] - start[0]
    return 100 * (1 - (end[1] - start[1]) / ticks) if ticks > 0 else None


def server_rate_samples(log):
    rows = re.findall(r"^SERVER_RATE (\d+) ([\d.]+) (\d+) (\d+) (\d+) (\d+)$", lines(log), re.M)
    return [(int(i), float(stamp), int(total), int(idle), int(size), int(calls))
            for i, stamp, total, idle, size, calls in rows]


def measure_group_rate(workers, runner, timing, server_samples):
    raw = lines(runner)
    start, end = map(int, re.search(r"^RATE_WINDOW_START (\d+) (\d+)$", raw, re.M).groups())
    seconds = (end - start) / 1e9
    host_seconds = timing["end"] - timing["start"]
    if seconds != RATE_SECONDS or host_seconds <= 0:
        raise RuntimeError(f"Invalid common read window: {runner}")

    mounts = {int(i): options.split(",") for i, options in re.findall(r"^RATE_MOUNT (\d+) (\S+)$", raw, re.M)}
    progress = {int(i): (int(first), int(last), int(size), int(calls))
                for i, first, last, size, calls in re.findall(
                    r"^RATE_FINAL (\d+) (\d+) (\d+) (\d+) (\d+)$", raw, re.M)}
    samples = {}
    for i, edge in re.findall(r"^RATE_SAMPLE_OK (\d+) (first|last)$", raw, re.M):
        samples.setdefault(int(i), []).append(edge)
    bad_samples = {int(i) for i in re.findall(r"^RATE_SAMPLE_ERROR (\d+) (?:first|last)$", raw, re.M)}
    for i, worker in workers.items():
        first, last, size, calls = progress.get(i, (None, None, 0, 0))
        if size and (not start <= first <= last <= end or not calls or "first" not in samples.get(i, [])):
            raise RuntimeError(f"Invalid completed-read record: client {i} in {runner}")
        if size and not {"ro", "vers=4.2", "rsize=1048576", "proto=tcp"} <= set(mounts.get(i, [])):
            raise RuntimeError(f"Unexpected negotiated mount options: client {i} in {runner}")
        worker["rate"] = {
            "bytes": size, "operations": calls, "mib_per_second": size / (1024 ** 2 * seconds),
            "first_completion_ns": first, "last_completion_ns": last,
            "first_read_latency_seconds": (first - start) / 1e9 if size else None,
            "read_sample_checks": samples.get(i, []), "mount_options": mounts.get(i),
        }
        if i in bad_samples:
            worker["result"] = "read_error"
        elif worker["result"] == "read_blocked":
            worker["result"] = "progress_by_deadline" if size else "no_data_by_deadline"
        elif worker["result"] == "read_complete":
            worker["result"] = "reader_returned" if size else "no_data_by_deadline"

    runner_cpu = {label: (int(total), int(idle)) for label, total, idle in re.findall(
        r"^RUNNER_CPU_(START|END) (\d+) (\d+)$", raw, re.M)}
    first, last = server_samples
    total = sum(worker["rate"]["bytes"] for worker in workers.values())
    return {
        "start_ns": start, "deadline_ns": end, "guest_seconds": seconds, "host_observed_seconds": host_seconds,
        "total_bytes": total, "guest_mib_per_second": total / (1024 ** 2 * seconds),
        "host_mib_per_second": total / (1024 ** 2 * host_seconds),
        "per_client_guest_mib_per_second": rate_distribution([worker["rate"]["mib_per_second"] for worker in workers.values()]),
        "first_read_latency_seconds": rate_distribution([
            worker["rate"]["first_read_latency_seconds"] for worker in workers.values() if worker["rate"]["bytes"]]),
        "zero_progress_clients": sum(worker["rate"]["bytes"] == 0 for worker in workers.values()),
        "runner_cpu_busy_percent": cpu_busy(runner_cpu["START"], runner_cpu["END"]),
        "server_cpu_busy_percent": cpu_busy(first[2:4], last[2:4]), "server_sample_seconds": last[1] - first[1],
        "server_read_bytes": last[4] - first[4], "server_nfs4_read_operations": last[5] - first[5],
    }


def check_group_rate_fixed(workers, runner):
    for i, worker in workers.items():
        if not worker["rate"]["bytes"] or worker["result"] == "read_error":
            raise RuntimeError(f"Fixed client {i} had no successful data or reported an error: {runner}")
        before, after = worker["rpc"]["BASE"], worker["rpc"]["DEADLINE"]
        if (before["CREATE_SESSION"][0] != 1 or before["DESTROY_SESSION"][0] != 0
                or any(before[op][0] != after[op][0] for op in ("EXCHANGE_ID", "CREATE_SESSION", "DESTROY_SESSION"))
                or after["READ"][0] <= before["READ"][0]):
            raise RuntimeError(f"Fixed client {i} had unstable NFS sessions or no READs: {runner}")
        if worker["rpc_network"]["retrans"] or any(row[0] != row[1] or row[2] or row[-1] for row in after.values()):
            raise RuntimeError(f"Fixed client {i} had NFS RPC retransmission, timeout, or error: {runner}")


def run_group_phase(work, qemu, kernel, archive, phase, initial_events, throughput=False, label=None):
    processes = []
    socket_type = socket.SOCK_DGRAM if throughput else socket.SOCK_STREAM
    client_link, server_link = socket.socketpair(socket.AF_UNIX, socket_type)
    try:
        measurement = "throughput" if throughput else "identity"
        server = start_vm(work, processes, qemu, kernel, archive, phase, "server", 0,
                          [(server_link, "02:50:58:45:00:11")], clients=GROUP_CLIENTS,
                          measurement=measurement, label=label)
        if not poll(processes, lambda: "SERVER_READY" in lines(server), 45, initial_events):
            raise RuntimeError(f"Group server did not reach ready state: {server}")
        runner = start_vm(work, processes, qemu, kernel, archive, phase, "runner", 0,
                          [(client_link, "02:50:58:45:00:12")], clients=GROUP_CLIENTS,
                          measurement=measurement, label=label)
        client_link.close()
        server_link.close()
        if (not poll(processes, lambda: "GROUP_MOUNT_WINDOW " in lines(runner) or "GROUP_SETUP_FAILED " in lines(runner),
                     100, initial_events)
                or "GROUP_SETUP_FAILED " in lines(runner)):
            raise RuntimeError(f"Not all {GROUP_CLIENTS} worker namespaces reached the barrier: {runner}")

        samples_seen = 0
        max_confirmed = 0
        stable_start = None
        stable_ids = None
        last_sample = None
        longest = 0.0
        proof = None
        rate_timing = {}
        rate_server = {}
        last_rate_sample = None

        def group_done():
            nonlocal samples_seen, max_confirmed, stable_start, stable_ids, last_sample, longest, proof, last_rate_sample
            raw = lines(runner)
            if throughput:
                received = time.monotonic()
                latest = server_rate_samples(server)
                if "RATE_WINDOW_START " in raw and "start" not in rate_timing:
                    rate_timing["start"] = received
                    rate_server["start"] = last_rate_sample or latest[-1]
                if "RATE_WINDOW_END" in raw and "end" not in rate_timing:
                    rate_timing["end"] = received
                    rate_server["end_sample_index"] = latest[-1][0]
                if "end" in rate_timing and "end" not in rate_server:
                    for sample in latest:
                        if sample[0] > rate_server["end_sample_index"]:
                            rate_server["end"] = sample
                            break
                if latest:
                    last_rate_sample = latest[-1]
                in_window = "start" in rate_timing and "end" not in rate_timing
            else:
                in_window = "GROUP_READ_WINDOW " in raw and "GROUP_DEADLINE " not in raw
            samples = read_owners(server, complete=True)
            for sample in samples[samples_seen:]:
                confirmed = {address: (owner, client) for address, owner, state, client in sample if state == "confirmed"}
                max_confirmed = max(max_confirmed, len(set(confirmed) & set(GROUP_HOSTS)))
                if phase != "fixed" or not in_window:
                    continue
                owners = [confirmed.get(host, ("", "")) for host in GROUP_HOSTS]
                valid = (all(f"rootpxe-{mac}" in owner for (owner, _), mac in zip(owners, GROUP_MACS))
                         and len({client for _, client in owners}) == GROUP_CLIENTS)
                now = time.monotonic()
                if not valid:
                    stable_start, stable_ids = None, None
                elif stable_ids != owners or now - last_sample > 5:
                    stable_start, stable_ids = now, owners
                elif now - stable_start > longest:
                    longest, proof = now - stable_start, dict(zip(GROUP_HOSTS, owners))
                last_sample = now
            samples_seen = len(samples)
            return "GROUP_DONE" in raw and (not throughput or "end" in rate_server)

        if not poll(processes, group_done, 200, initial_events):
            raise RuntimeError(f"Group observation deadlines did not complete: {runner}")
        workers = group_records(runner, phase)
        result = {"phase": phase, "max_confirmed": max_confirmed, "clients": workers}
        if throughput:
            result["rate"] = measure_group_rate(workers, runner, rate_timing, (rate_server["start"], rate_server["end"]))
        if phase == "baseline":
            owner_rows = [row for sample in read_owners(server, complete=True) for row in sample]
            seen_owners = {row[1] for row in owner_rows if row[0] in GROUP_HOSTS}
            attached = re.findall(r'v4\.2 client attached: (0x[0-9a-f]+) from "([^"]+):\d+"', lines(server))
            ids = {host: set() for host in GROUP_HOSTS}
            for clientid, host in attached:
                if host in ids:
                    ids[host].add(clientid)
            result["server_attached_ids"] = {host: sorted(values) for host, values in ids.items()}
            result["observed_owners"] = sorted(seen_owners)
        else:
            result["all_confirmed_seconds"] = longest
            result["server_confirmed_ids"] = proof
        report = work / f"{label or phase}-clients.json"
        report.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        if phase == "baseline":
            if (seen_owners != {"Linux NFSv4.2 pxeos"} or sum(bool(values) for values in ids.values()) < 2
                    or not any(len(values) > 1 for values in ids.values())):
                raise RuntimeError(f"Identical owner and server ID churn were not observed: {server}")
        else:
            if longest < 30:
                raise RuntimeError(f"Expected {GROUP_CLIENTS} stable confirmed owners for 30 wall seconds, observed {longest:.2f}: {server}")
            if throughput:
                check_group_rate_fixed(workers, runner)
            else:
                check_group_fixed(workers)
        states = dict(Counter(worker["result"] for worker in workers.values()))
        print(f"GROUP phase={phase} workers={len(workers)} results={states} "
              f"late_mounts={sum(worker['mount_late'] for worker in workers.values())} "
              f"max_confirmed={max_confirmed} all_confirmed_seconds={longest:.2f} report={report}", flush=True)
        if throughput:
            rate = result["rate"]
            print(f"RATE {label} bytes={rate['total_bytes']} guest_MiB_s={rate['guest_mib_per_second']:.3f} "
                  f"host_seconds={rate['host_observed_seconds']:.3f} host_MiB_s={rate['host_mib_per_second']:.3f} "
                  f"zero_progress={rate['zero_progress_clients']}", flush=True)
            return rate
    finally:
        client_link.close()
        server_link.close()
        stop_vms(processes)


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qemu-tree", type=Path, required=True, help="extracted QEMU/SeaBIOS with usr/ paths")
    parser.add_argument("--kernel-deb", type=Path, required=True, help="Ubuntu linux-image package with documented checksum")
    parser.add_argument("--server-deb", type=Path, required=True, help="Ubuntu nfs-kernel-server package with documented checksum")
    parser.add_argument("--clients", type=int, choices=(2, GROUP_CLIENTS), default=2,
                        help="independent QEMU client kernels (2) or client network namespaces in a runner guest (50)")
    parser.add_argument("--throughput", action="store_true", help="run 50-client unpaced direct reads in AB/BA order")
    args = parser.parse_args()
    if args.throughput and args.clients != GROUP_CLIENTS:
        parser.error("--throughput requires --clients 50")
    if (SLICE.name != "codexbuildtest.slice" or (SLICE / "memory.max").read_text().strip() != "8589934592"
            or (SLICE / "memory.swap.max").read_text().strip() != "34359738368"):
        sys.exit("Must run under codex-build-test with confirmed shared limits")
    work = Path(tempfile.mkdtemp(prefix="rootpxe-nfs-qemu-", dir="/tmp"))
    print(f"LOG_DIR={work}", flush=True)
    initial_events = limit_events()
    try:
        kernel, archive = make_fixture(work, args.kernel_deb, args.server_deb, args.clients, args.throughput)
        run = run_phase if args.clients == 2 else run_group_phase
        phases = ("baseline", "fixed", "fixed", "baseline") if args.throughput else ("baseline", "fixed")
        rates = []
        for number, phase in enumerate(phases, 1):
            if limit_events() != initial_events:
                raise RuntimeError("Shared cgroup reached a memory or swap limit")
            if args.throughput:
                label = f"{number:02d}-{phase}"
                rate = run_group_phase(work, args.qemu_tree, kernel, archive, phase, initial_events,
                                       throughput=True, label=label)
                rates.append({"label": label, "phase": phase, **rate})
            else:
                run(work, args.qemu_tree, kernel, archive, phase, initial_events)
        if limit_events() != initial_events:
            raise RuntimeError("Shared cgroup reached a memory or swap limit")
        if rates:
            ratios = {}
            for order, baseline, fixed in (("AB", rates[0], rates[1]), ("BA", rates[3], rates[2])):
                ratios[order] = {
                    key: fixed[key] / baseline[key] if baseline[key] else None
                    for key in ("guest_mib_per_second", "host_mib_per_second")
                }
                print(f"RATE_RATIO {order} {ratios[order]}", flush=True)
            report = work / "throughput-comparison.json"
            report.write_text(json.dumps({"runs": rates, "fixed_over_baseline": ratios}, indent=2) + "\n")
            print(f"RATE_COMPARISON={report}", flush=True)
    finally:
        for name in ("memory.peak", "memory.swap.peak", "memory.events", "memory.swap.events"):
            print(f"{name} scope={(CGROUP / name).read_text().strip()}", flush=True)

