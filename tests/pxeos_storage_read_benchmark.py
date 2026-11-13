"""Compare local PXEOS read paths using warm files and real helper/controller IPC."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import signal
from statistics import median
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parents[1]
NATIVE = Path("Buildroot/package/rootpxe-storage-io/src")
CONTROLLER = Path("Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/storage-io.sh")
WORKER = r'''
set -e
fixture=$1
source_root=$2
lib=$3
count=$4
mkfifo restore
if [[ $lib == old ]]; then
    cat -- "$source_root/image/part.img" >restore &
    reader=$!
    sha256sum <restore
    wait "$reader"
    exit
fi
source "$lib"
if [[ $count == yes ]]; then
    jq() { printf '.\n' >>jq.calls; command jq "$@"; }
fi
rootpxe_storage_call() {
    local event=${3#event=}
    printf '%s\n' "$event" >>checkpoints
    command jq -c --slurpfile p "$source_root/proof.json" '
        {nextSequence: (((.sequence|tonumber)+1)|tostring),
         ack: (. + {phase:.event,event:"ack",proof:$p[0]})}' <<<"$event"
}
rootpxe_storage_workspace=$PWD
printf '1\n' >next-sequence
printf '%s\n' '{"execution":{"taskType":"deploy"}}' >context.json
mkfifo request data events
"$fixture" benchmark-helper "$source_root" request data events &
rootpxe_storage_pid=$!
exec {rootpxe_storage_request_fd}>request
exec {rootpxe_storage_data_fd}<data
exec {rootpxe_storage_result_fd}<events
rootpxe_storage_exec read image/part.img - >restore &
reader=$!
sha256sum <restore
wait "$reader"
wait "$rootpxe_storage_pid"
'''


def compile_fixture(source, binary):
    flags = os.environ.get("ROOTPXE_STORAGE_BENCHMARK_FLAGS")
    if flags is None:
        flags = subprocess.check_output(
            [os.environ.get("PKG_CONFIG", "pkg-config"), "--cflags", "--libs", "json-c", "openssl"],
            text=True,
        )
    subprocess.run([
        os.environ.get("CC", "cc"), "-O2", "-std=c11", "-D_GNU_SOURCE", "-D_FILE_OFFSET_BITS=64",
        "-I", source, REPO / "tests/storage_fs_fixture.c", source / "storage_fs.c",
        source / "storage_context.c", *shlex.split(flags), "-o", binary,
    ], check=True)


def run_case(case, fixture, library, source, size, expected, concurrency, directory, count):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.perf_counter()
    children = []
    completed = False
    try:
        for index in range(concurrency):
            path = directory / str(index)
            path.mkdir(parents=True)
            args = ["bash", "-c", WORKER, case, fixture, source, library, "yes" if count else "no"]
            child = subprocess.Popen(args, cwd=path, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=True, text=True)
            children.append((child, path))
        for child, _ in children:
            output, error = child.communicate(timeout=25)
            if child.returncode or output.split() != [expected, "-"]:
                raise RuntimeError(f"{case}: invalid data or worker exit {child.returncode}: {error}")
        completed = True
    finally:
        if not completed:
            for child, _ in children:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        for child, _ in children:
            child.wait()
            child.stdout.close()
            child.stderr.close()
    elapsed = time.perf_counter() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    calls = 0
    if case != "old":
        for _, path in children:
            events = [json.loads(line) for line in (path / "checkpoints").read_text().splitlines()]
            if [event["event"] for event in events] != ["intent", "result"]:
                raise RuntimeError(f"{case}: unexpected checkpoint sequence")
            node = events[1]["node"]
            if node["sha256"] != expected or int(node["size"]) != size << 20:
                raise RuntimeError(f"{case}: incorrect helper result")
            if count:
                calls += len((path / "jq.calls").read_text().splitlines())
    rate = size * concurrency / elapsed
    user = after.ru_utime - before.ru_utime
    system = after.ru_stime - before.ru_stime
    print(f"{case} jobs={concurrency} MiB={size * concurrency} wall={elapsed:.4f}s "
          f"MiB/s={rate:.2f} user={user:.4f}s sys={system:.4f}s jq={calls if count else '-'}",
          flush=True)
    return rate, user + system


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="00384223", help="commit for the previous helper and controller")
    args = parser.parse_args()
    size = 96
    with tempfile.TemporaryDirectory(prefix="pxeos-read-benchmark-") as temporary:
        work = Path(temporary)
        baseline = work / "baseline"
        baseline.mkdir()
        for path in [NATIVE / name for name in ("storage_fs.c", "storage_fs.h", "storage_context.c",
                                                  "storage_context.h")] + [CONTROLLER]:
            (baseline / path.name).write_bytes(subprocess.check_output(
                ["git", "-C", REPO, "show", f"{args.baseline}:{path}"]))
        old_helper, new_helper = work / "baseline-helper", work / "current-helper"
        compile_fixture(baseline, old_helper)
        compile_fixture(REPO / NATIVE, new_helper)
        source = work / "files"
        (source / "image").mkdir(parents=True)
        chunk = hashlib.shake_256(b"local-fixture").digest(1 << 20)
        payload = source / "image/part.img"
        with payload.open("wb") as output:
            for _ in range(size):
                output.write(chunk)
        with payload.open("rb") as data:
            expected = hashlib.file_digest(data, "sha256").hexdigest()
        with (source / "proof.json").open("w") as proof:
            subprocess.run([new_helper, "benchmark-proof", source], stdout=proof, check=True)
        print(f"Warm local file: {size} MiB per job, SHA-256={expected}", flush=True)
        variants = {
            "old": (new_helper, "old"),
            "baseline": (old_helper, baseline / CONTROLLER.name),
            "current": (new_helper, REPO / CONTROLLER),
        }
        for concurrency in (1, 4):
            measurements = {case: [] for case in variants}
            order = list(variants)
            for run in range(3):
                for case in order[run:] + order[:run]:
                    fixture, library = variants[case]
                    sample = run_case(case, fixture, library, source, size, expected, concurrency,
                                      work / f"{concurrency}-{run}-{case}", False)
                    measurements[case].append(sample)
            for case, samples in measurements.items():
                print(f"median {case} jobs={concurrency} MiB/s={median(x[0] for x in samples):.2f} "
                      f"CPU={median(x[1] for x in samples):.4f}s")
            for case in ("baseline", "current"):
                fixture, library = variants[case]
                run_case(case, fixture, library, source, size, expected, concurrency,
                         work / f"{concurrency}-count-{case}", True)


if __name__ == "__main__":
    main()
