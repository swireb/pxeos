"""Compare local PXEOS read paths using warm files and real helper/controller IPC."""

import argparse
from contextlib import ExitStack
from dataclasses import dataclass, field
import hashlib
import json
from math import ceil
import os
from pathlib import Path
import resource
import select
import selectors
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
    printf . >&"$5"
    IFS= read -r -n 1 -u "$6" start
    [[ $start == . ]]
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
printf '%s\n' '{"cleanupOnly":false}' >preflight.json
mkfifo request data events
ROOTPXE_BENCHMARK_READY=$7 ROOTPXE_BENCHMARK_GATE=$8 \
    "$fixture" benchmark-helper "$source_root" request data events &
rootpxe_storage_pid=$!
exec {rootpxe_storage_request_fd}>request
exec {rootpxe_storage_data_fd}<data
exec {rootpxe_storage_result_fd}<events
sha256sum <restore &
consumer=$!
printf . >&"$5"
IFS= read -r -n 1 -u "$6" start
[[ $start == . ]]
rootpxe_storage_exec read image/part.img - >restore &
reader=$!
wait "$reader"
wait "$consumer"
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
        "-DROOTPXE_TEST_BENCHMARK", "-Wl,--wrap=write",
        "-I", source, REPO / "tests/storage_fs_fixture.c", source / "storage_fs.c",
        source / "storage_context.c", *shlex.split(flags), "-o", binary,
    ], check=True)


def wait_ready(fd, count, children, timeout):
    deadline = time.monotonic() + timeout
    ready = 0
    while ready < count:
        exited = [(index, child.returncode) for index, (child, _) in enumerate(children)
                  if child.poll() is not None]
        if exited:
            raise RuntimeError(f"ready={ready}/{count}, first worker exits={exited[:4]}")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"ready={ready}/{count}")
        if select.select([fd], [], [], min(remaining, 0.1))[0]:
            payload = os.read(fd, count - ready)
            if not payload or payload != b"." * len(payload):
                raise RuntimeError(f"malformed ready signal at {ready}/{count}")
            ready += len(payload)
    return ready


def max_overlap(intervals):
    boundaries = [(when, change) for first, last in intervals
                  for when, change in ((first, 1), (last, -1))]
    active = peak = 0
    for _, change in sorted(boundaries):
        active += change
        peak = max(peak, active)
    return peak


@dataclass
class NativeRead:
    process: subprocess.Popen
    workspace: Path
    request: object
    owner: dict
    size: int
    expected: str
    proof: dict
    digest: object = field(default_factory=hashlib.sha256)
    events: bytearray = field(default_factory=bytearray)
    received: int = 0
    phase: int = 0
    event_eof: bool = False
    data_eof: bool = False

    def put(self, message):
        self.request.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")

    def event(self, event):
        if event.get("event") == "progress":
            if self.phase != 1 or event.get("stage") != "read":
                raise ValueError("unexpected progress event")
            return
        if self.phase >= 3:
            raise ValueError("unexpected event after done")
        expected_phase = ("intent", "result", "done")[self.phase]
        seq = str(min(self.phase + 1, 2))
        if event.get("event") != expected_phase or event.get("sequence") != seq:
            raise ValueError(f"expected {expected_phase} sequence {seq}")
        if expected_phase != "done":
            if (event.get("execution"), event.get("path"), event.get("operation")) != (
                    self.owner, "image/part.img", "read"):
                raise ValueError("checkpoint is for a different task or file")
            if expected_phase == "result":
                node = event["node"]
                file_proof = self.proof[hashlib.sha256(b"image/part.img").hexdigest()]
                if (node["size"], node["fileId"], node["kind"]) != (
                        str(self.size), file_proof["fileId"], "file") or "sha256" in node:
                    raise ValueError("incorrect native read result")
            self.put({**event, "event": "ack", "phase": expected_phase, "proof": self.proof})
        self.phase += 1


def start_native_read(fixture, source, size, expected, proof, index, directory,
                      ready_write, gate_read, selector, stack):
    workspace = directory / str(index)
    workspace.mkdir(parents=True)
    owner = {"taskType": "deploy", "taskId": str(index + 1)}
    protocol = ("nfs", "smb")[index % 2]
    (workspace / "context.json").write_text(json.dumps({"execution": owner, "protocol": protocol}))
    with ExitStack() as child_fds, (workspace / "stderr").open("wb") as error:
        request_read, request_write = os.pipe()
        child_fds.callback(os.close, request_read)
        request = stack.enter_context(os.fdopen(request_write, "wb", buffering=0))
        data_read, data_write = os.pipe()
        child_fds.callback(os.close, data_write)
        data = stack.enter_context(os.fdopen(data_read, "rb", buffering=0))
        event_read, event_write = os.pipe()
        child_fds.callback(os.close, event_write)
        events = stack.enter_context(os.fdopen(event_read, "rb", buffering=0))
        process = subprocess.Popen(
            [fixture, "benchmark-helper", source, *[f"/proc/self/fd/{fd}"
                                                     for fd in (request_read, data_write, event_write)]],
            cwd=workspace, stdout=subprocess.DEVNULL, stderr=error, start_new_session=True,
            pass_fds=(request_read, data_write, event_write, ready_write, gate_read),
            env={**os.environ, "ROOTPXE_BENCHMARK_READY": str(ready_write),
                 "ROOTPXE_BENCHMARK_GATE": str(gate_read)},
        )
    job = NativeRead(process, workspace, request, owner, size, expected, proof)
    selector.register(data, selectors.EVENT_READ, (job, "data"))
    selector.register(events, selectors.EVENT_READ, (job, "events"))
    return job


def run_native_case(fixture, sources, concurrency, directory, timeout=300):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    parent_before = time.process_time()
    launched = time.monotonic_ns()
    jobs = []
    ready = released = 0
    stage = "starting"
    with ExitStack() as stack:
        selector = stack.enter_context(selectors.DefaultSelector())
        ready_read, ready_write = os.pipe()
        gate_read, gate_write = os.pipe()
        for fd in (ready_read, ready_write, gate_read, gate_write):
            stack.callback(os.close, fd)
        selector.register(ready_read, selectors.EVENT_READ, (None, "ready"))
        try:
            proofs = [json.loads((source / "proof.json").read_text()) for source, _, _ in sources]
            for index in range(concurrency):
                slot = index % len(sources)
                job = start_native_read(fixture, *sources[slot], proofs[slot], index, directory,
                                        ready_write, gate_read, selector, stack)
                jobs.append(job)
            stage = "bulk-ready"
            for job in jobs:
                job.put({"operation": "read", "path": "image/part.img", "sequence": "1",
                         "execution": job.owner, "skipReadDigest": True})
            deadline = time.monotonic() + timeout
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"native {stage} deadline exceeded")
                for key, _ in selector.select(remaining):
                    job, kind = key.data
                    block = os.read(key.fd, 131072 if kind == "data" else 4096)
                    if kind == "ready":
                        if not block or block != b"." * len(block) or ready + len(block) > concurrency:
                            raise ValueError("invalid native ready signal")
                        ready += len(block)
                        if ready == concurrency:
                            if any(task.phase != 1 for task in jobs):
                                raise ValueError("native ready before intent ACK")
                            selector.unregister(ready_read)
                            stage = "transferring"
                            released = time.monotonic_ns()
                            os.write(gate_write, b"." * concurrency)
                            deadline = time.monotonic() + timeout
                    elif not block:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        if kind == "data":
                            job.data_eof = True
                        elif job.phase != 3 or job.events:
                            raise ValueError(f"task {job.owner['taskId']} ended before complete receipts")
                        else:
                            job.event_eof = True
                    elif kind == "data":
                        if not released:
                            raise ValueError("native copied data before the gate")
                        job.received += len(block)
                        job.digest.update(block)
                    else:
                        job.events.extend(block)
                        while (newline := job.events.find(b"\n")) >= 0:
                            if newline > 65536:
                                raise ValueError("native event exceeded 64 KiB")
                            event = json.loads(job.events[:newline])
                            del job.events[:newline + 1]
                            job.event(event)
                        if len(job.events) > 65536:
                            raise ValueError("native partial event exceeded 64 KiB")
            for job in jobs:
                if (job.process.wait(timeout=max(0, deadline - time.monotonic())) or not job.event_eof or
                        not job.data_eof or job.received != job.size or
                        job.digest.hexdigest() != job.expected):
                    raise ValueError(f"native task {job.owner['taskId']} failed byte, digest or exit checks")
        except (ValueError, OSError, KeyError, IndexError, subprocess.TimeoutExpired) as exc:
            print(f"native jobs={concurrency} launched={len(jobs)} ready={ready} stage={stage} "
                  f"completed_done={sum(job.phase == 3 for job in jobs)} errors=1 "
                  f"timeout={int(isinstance(exc, (TimeoutError, subprocess.TimeoutExpired)))} detail={exc}",
                  flush=True)
            raise
        finally:
            pending = [job.process for job in jobs if job.process.poll() is None]
            for process in pending:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            for process in pending:
                process.wait()

    ended = time.monotonic_ns()
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    timings = [tuple(map(int, (job.workspace / "timing").read_text().split())) for job in jobs]
    if any(not released <= first < last <= done <= ended for first, last, done in timings):
        raise ValueError("invalid native interval")
    active = max_overlap((first, last) for first, last, _ in timings)
    elapsed = (ended - released) / 1e9
    total_bytes = sum(job.received for job in jobs)
    bulk = (max(last for _, last, _ in timings) - released) / 1e9
    completion = sorted((done - released) / 1e9 for _, _, done in timings)
    start_span = (max(first for first, _, _ in timings) - min(first for first, _, _ in timings)) / 1e9
    print(f"native jobs={concurrency} ready={ready} max_active={active} bytes={total_bytes} "
          f"hash_ok={len(jobs)} intent_ok={len(jobs)} result_ok={len(jobs)} done_ok={len(jobs)} "
          f"errors=0 timeouts=0 wall_s={elapsed:.4f} total_s={(ended-launched)/1e9:.4f} "
          f"bulk_s={bulk:.4f} bulk_MiB/s={total_bytes/(1<<20)/bulk:.2f} "
          f"MiB/s={total_bytes/(1<<20)/elapsed:.2f} start_span_s={start_span:.4f} "
          f"p50_s={median(completion):.4f} p95_s={completion[ceil(len(completion)*0.95)-1]:.4f} "
          f"max_s={completion[-1]:.4f} CPU_s={after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime:.4f}"
          f" driver_CPU_s={time.process_time()-parent_before:.4f}",
          flush=True)
    if active != concurrency:
        raise SystemExit(f"jobs={concurrency}: only {active} actual native data intervals overlapped")


def run_case(case, fixture, library, sources, concurrency, directory, count=False,
             timeout=300):
    children = []
    inputs = []
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    stage = "start"
    complete = False
    released = time.monotonic_ns()
    launched = released
    with ExitStack() as fds:
        start_ready, start_signal = os.pipe()
        start_wait, start_gate = os.pipe()
        data_ready, data_signal = os.pipe()
        data_wait, data_gate = os.pipe()
        for fd in (start_ready, start_signal, start_wait, start_gate,
                   data_ready, data_signal, data_wait, data_gate):
            fds.callback(os.close, fd)
        try:
            for index in range(concurrency):
                path = directory / str(index)
                path.mkdir(parents=True)
                source, size, expected = sources[index % len(sources)]
                protocol = ("nfs", "smb")[index % 2]
                owner = {"taskType": "deploy", "taskId": str(index + 1)}
                (path / "context.json").write_text(json.dumps({
                    "execution": owner, "protocol": protocol,
                }))
                inputs.append((size, expected, owner))
                worker_fds = (start_signal, start_wait, data_signal, data_wait)
                args = ["bash", "-c", WORKER, case, fixture, source, library,
                        "yes" if count else "no", *map(str, worker_fds)]
                with (path / "stdout").open("wb") as output, (path / "stderr").open("wb") as errors:
                    child = subprocess.Popen(args, cwd=path, stdout=output, stderr=errors,
                                             start_new_session=True, pass_fds=worker_fds)
                children.append((child, path))
            stage = "controller-ready"
            ready = wait_ready(start_ready, concurrency, children, timeout)
            if case == "old":
                released = time.monotonic_ns()
            os.write(start_gate, b"." * concurrency)
            bulk_ready = 0
            if case != "old":
                stage = "bulk-ready"
                bulk_ready = wait_ready(data_ready, concurrency, children, 25)
                released = time.monotonic_ns()
                os.write(data_gate, b"." * concurrency)
            stage = "completion"
            deadline = time.monotonic() + timeout
            timed_out = False
            for child, _ in children:
                try:
                    child.wait(timeout=max(deadline - time.monotonic(), 0))
                except subprocess.TimeoutExpired:
                    timed_out = True
                    break
            complete = not timed_out and all(child.returncode == 0 for child, _ in children)
        except (OSError, RuntimeError, TimeoutError) as exc:
            print(f"{case} jobs={concurrency} started={len(children)} stage={stage} error={exc}",
                  flush=True)
            raise
        finally:
            if not complete:
                for child, _ in children:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                for child, _ in children:
                    child.wait()
    ended = time.monotonic_ns()
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    failures = []
    intervals = []
    completion = []
    calls = total_bytes = 0
    for index, ((child, path), (size, expected, owner)) in enumerate(zip(children, inputs)):
        try:
            if child.returncode:
                errors = (path / "stderr").read_text(errors="replace").splitlines()
                raise ValueError(f"worker status {child.returncode}: {errors[-2:]}")
            if (path / "stdout").read_text().split() != [expected, "-"]:
                raise ValueError("incorrect consumer SHA-256")
            if case != "old":
                events = [json.loads(line) for line in (path / "checkpoints").read_text().splitlines()]
                if [event["event"] for event in events] != ["intent", "result"]:
                    raise ValueError("unexpected checkpoint sequence")
                for event, sequence in zip(events, ("1", "2")):
                    if (event["sequence"], event["path"], event["execution"]) != (
                            sequence, "image/part.img", owner):
                        raise ValueError("checkpoint is for a different task or file")
                node = events[1]["node"]
                if int(node["size"]) != size or (case == "current" and "sha256" in node):
                    raise ValueError("incorrect helper result")
                if case != "current" and node["sha256"] != expected:
                    raise ValueError("incorrect helper digest")
                first, last, finished = map(int, (path / "timing").read_text().split())
                if not released <= first < last <= finished <= ended:
                    raise ValueError("missing or inconsistent transfer timing")
                intervals.append((first, last))
                completion.append((finished - released) / 1e9)
                if count:
                    calls += len((path / "jq.calls").read_text().splitlines())
            total_bytes += size
        except (OSError, ValueError, KeyError) as exc:
            failures.append((index + 1, str(exc)))
    elapsed = (ended - released) / 1e9
    rate = total_bytes / (1 << 20) / elapsed
    user = after.ru_utime - before.ru_utime
    system = after.ru_stime - before.ru_stime
    measured = ""
    active = 0
    if intervals:
        earliest = min(first for first, _ in intervals)
        latest = max(first for first, _ in intervals)
        last = max(last for _, last in intervals)
        bulk_seconds = (last - released) / 1e9
        completion.sort()
        active = max_overlap(intervals)
        measured = (f" max_active={active} start_span_s={(latest-earliest)/1e9:.4f}"
                    f" bulk_s={bulk_seconds:.4f} bulk_MiB/s={total_bytes/(1<<20)/bulk_seconds:.2f}"
                    f" p50_s={median(completion):.4f} p95_s={completion[ceil(len(completion)*0.95)-1]:.4f}"
                    f" max_s={completion[-1]:.4f}")
    print(f"{case} jobs={concurrency} ready={ready} bulk_ready={bulk_ready} "
          f"bytes={total_bytes} wall={elapsed:.4f}s total_s={(ended-launched)/1e9:.4f} MiB/s={rate:.2f} "
          f"user={user:.4f}s sys={system:.4f}s errors={len(failures)} "
          f"deadline_timeout={int(timed_out)} jq={calls if count else '-'}{measured}", flush=True)
    if failures:
        raise RuntimeError(f"{case}: {len(failures)} workers failed: {failures[:5]}")
    overlap_ok = case == "old" or active == concurrency
    if not overlap_ok:
        print(f"{case} jobs={concurrency} status=insufficient_overlap actual={active}",
              flush=True)
    return rate, user + system, overlap_ok


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="00384223", help="commit for the previous helper and controller")
    parser.add_argument("--jobs", nargs="+", type=int, default=[1, 4])
    parser.add_argument("--size-mib", type=int, default=96)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--compare-only", action="store_true",
                        help="skip direct cat and extra jq counting runs")
    parser.add_argument("--native-only", action="store_true",
                        help="measure current native helpers with a shared test driver and consumer")
    args = parser.parse_args()
    if not (1 <= args.size_mib <= 128 and 1 <= args.runs <= 5 and
            all(1 <= jobs <= 500 for jobs in args.jobs)):
        parser.error("allowed ranges: --size-mib 1–128, --runs 1–5, --jobs 1–500")
    with tempfile.TemporaryDirectory(prefix="pxeos-read-benchmark-") as temporary:
        work = Path(temporary)
        new_helper = work / "current-helper"
        if not args.native_only:
            baseline = work / "baseline"
            baseline.mkdir()
            for path in [NATIVE / name for name in ("storage_fs.c", "storage_fs.h", "storage_context.c",
                                                      "storage_context.h")] + [CONTROLLER]:
                (baseline / path.name).write_bytes(subprocess.check_output(
                    ["git", "-C", REPO, "show", f"{args.baseline}:{path}"]))
            old_helper = work / "baseline-helper"
            compile_fixture(baseline, old_helper)
        compile_fixture(REPO / NATIVE, new_helper)
        sources = []
        grouped_sources = args.compare_only or args.native_only
        for index in range(4 if grouped_sources else 1):
            source = work / f"files-{index}"
            (source / "image").mkdir(parents=True)
            tag = f"local-fixture-{index}".encode()
            chunk = hashlib.shake_256(tag).digest(1 << 20)
            payload = source / "image/part.img"
            with payload.open("wb") as output:
                for _ in range(args.size_mib):
                    output.write(chunk)
                if grouped_sources:
                    output.write(tag[:index + 1])
            payload.chmod(0o400)
            with payload.open("rb") as data:
                expected = hashlib.file_digest(data, "sha256").hexdigest()
            with (source / "proof.json").open("w") as proof:
                subprocess.run([new_helper, "benchmark-proof", source], stdout=proof, check=True)
            size = payload.stat().st_size
            sources.append((source, size, expected))
            print(f"Warm local file: source={index} bytes={size} SHA-256={expected}", flush=True)
        if args.native_only:
            for jobs in args.jobs:
                for run in range(args.runs):
                    run_native_case(new_helper, sources, jobs, work / f"{jobs}-{run}-native")
            return
        variants = {
            "baseline": (old_helper, baseline / CONTROLLER.name),
            "current": (new_helper, REPO / CONTROLLER),
        }
        if not args.compare_only:
            variants = {"old": (new_helper, "old"), **variants}
        for group, jobs in enumerate(args.jobs):
            measurements = {case: [] for case in variants}
            order = list(variants)
            for run in range(args.runs):
                offset = (group + run) % len(order)
                for case in order[offset:] + order[:offset]:
                    fixture, library = variants[case]
                    sample = run_case(case, fixture, library, sources, jobs,
                                      work / f"{jobs}-{run}-{case}")
                    measurements[case].append(sample)
            for case, samples in measurements.items():
                print(f"median {case} jobs={jobs} MiB/s={median(x[0] for x in samples):.2f} "
                      f"CPU={median(x[1] for x in samples):.4f}s", flush=True)
            if not all(sample[2] for samples in measurements.values() for sample in samples):
                raise SystemExit(f"jobs={jobs}: full overlap not reached for both compared versions")
            if not args.compare_only:
                for case in ("baseline", "current"):
                    fixture, library = variants[case]
                    run_case(case, fixture, library, sources, jobs,
                             work / f"{jobs}-count-{case}", True)


if __name__ == "__main__":
    main()
