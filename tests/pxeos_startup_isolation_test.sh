#!/usr/bin/env bash
# Exercise the isolation entry points with harmless stand-ins.
set -euo pipefail

tests=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
runner="$tests/run-startup-regression.sh"
bash "$runner" --probe

tmp=$(mktemp -d "${TMPDIR:-/var/tmp}/pxeos-isolation-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/tests"
cp -- "$runner" "$tmp/tests/"
printf 'echo fixture-must-not-run\n' >"$tmp/tests/pxeos_network_storage_regression.sh"
printf '#!/bin/sh\necho simulated-bwrap-failure >&2\nexit 42\n' >"$tmp/failing-bwrap"
chmod 500 "$tmp/failing-bwrap"
: >"$tmp/unavailable-bwrap"

for scenario in unavailable failing; do
    status=0
    /usr/bin/bwrap --unshare-user --unshare-pid --unshare-net --disable-userns --cap-drop ALL \
        --new-session --die-with-parent --clearenv --setenv PATH /usr/bin:/usr/sbin \
        --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin \
        --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
        --ro-bind "$tmp/$scenario-bwrap" /usr/bin/bwrap --ro-bind "$tmp/tests" /tests \
        --proc /proc --remount-ro /proc --dev /dev --tmpfs /var/tmp \
        -- /usr/bin/bash /tests/run-startup-regression.sh pxeos_network_storage_regression.sh \
        >"$tmp/$scenario.log" 2>&1 || status=$?
    if [[ $scenario == unavailable ]]; then
        [[ $status == 125 ]]
        grep -Fq 'bubblewrap is required' "$tmp/$scenario.log"
    else
        [[ $status == 42 ]]
        grep -Fq 'simulated-bwrap-failure' "$tmp/$scenario.log"
    fi
    ! grep -Fq 'fixture-must-not-run' "$tmp/$scenario.log" || exit 1
    printf 'PASS: refused %s bubblewrap\n' "$scenario"
done

# Copy the real entry points without production sources so a guard regression
# cannot execute any PXEOS startup or power code.
for entry in pxeos_network_storage_regression.sh pxeos_manual_registration_regression.sh pxeos_storage_controller_test.py; do
    cp -- "$tests/$entry" "$tmp/tests/"
    command=(bash)
    [[ $entry != *.py ]] || command=(python3 -B)
    status=0
    PXEOS_STARTUP_TEST_ISOLATED=1 "${command[@]}" "$tmp/tests/$entry" >"$tmp/forged.log" 2>&1 || status=$?
    if [[ $entry == *.py ]]; then
        [[ $status == 1 ]]
        grep -Fq 'to enter the PXEOS test sandbox' "$tmp/forged.log"
    else
        [[ $status == 125 ]]
    fi
    printf 'PASS: rejected forged isolation flag for %s\n' "$entry"
done
