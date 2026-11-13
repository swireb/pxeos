#!/usr/bin/env bash
# Isolate tests that execute PXEOS init or power-action code.
set -euo pipefail

fail() { printf 'PXEOS test isolation: %s\n' "$*" >&2; exit 125; }

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_name=${1:-}
fixture_mounts=()
case "$test_name" in
    --manual-http-integration)
        [[ $# == 2 ]] || fail 'manual HTTP integration requires one test binary'
        cache_root=$(readlink -e -- "$test_dir/../../../backend/.build-cache") || fail 'backend test cache missing'
        test_binary=$(readlink -e -- "$2") || fail 'test binary missing'
        [[ $test_binary == "$cache_root/"* && -f $test_binary && -x $test_binary ]] || fail 'test binary must be in backend/.build-cache'
        fixture_mounts+=(--ro-bind "$test_binary" /manual-pxeos-integration.test)
        fixture_mounts+=(--setenv GOMAXPROCS 1 --setenv GOMEMLIMIT 768MiB)
        command=(/manual-pxeos-integration.test -test.run '^TestManualPXEOSHTTPSIntegration$' -test.v -test.timeout=90s)
        shift
        ;;
    pxeos_network_storage_regression.sh|pxeos_manual_registration_regression.sh|pxeos_capture_metadata_test.sh)
        command=(/usr/bin/bash "/pxeos/tests/$test_name")
        ;;
    pxeos_storage_controller_test.py)
        command=(/usr/bin/python3 -B "/pxeos/tests/$test_name")
        ;;
    --probe)
        [[ $# == 1 ]] || fail '--probe accepts no arguments'
        command=()
        ;;
    *)
        fail 'expected a startup regression test name or --probe'
        ;;
esac
shift

[[ -x /usr/bin/bwrap ]] || fail 'bubblewrap is required'
[[ /bin -ef /usr/bin && /sbin -ef /usr/sbin && /lib -ef /usr/lib ]] \
    || fail 'a merged /usr filesystem is required'
scratch=$(mktemp -d "${TMPDIR:-/var/tmp}/pxeos-startup.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/tmp"
if [[ $test_name == --manual-http-integration ]]; then
    printf '%s\n' 0123456789abcdef0123456789abcdef > "$scratch/machine-id"
    fixture_mounts+=(--ro-bind "$scratch/machine-id" /etc/machine-id)
fi
cat > "$scratch/deny" <<'EOF'
#!/bin/sh
printf '%s\n' "${0##*/}" >> /tmp/.unexpected-power-command
exit 125
EOF
chmod 500 "$scratch/deny"

# Mask executable targets so both PATH lookup and absolute symlinks hit the deny
# script. The sandbox also removes access to the host buses, even via other tools.
declare -A denied
mounts=()
for file in /usr/{bin,sbin}/{reboot,poweroff,shutdown,halt,telinit,init,systemctl,loginctl,busybox} \
    /usr/lib/systemd/{systemd,systemd-shutdown,systemd-logind}; do
    [[ -f $file ]] || continue
    target=$(readlink -e -- "$file")
    [[ $target == /usr/* ]] || fail "unexpected system command target: $target"
    [[ ! ${denied[$target]+found} ]] || continue
    denied[$target]=1
    mounts+=(--ro-bind "$scratch/deny" "$target")
done

host_namespaces=$(readlink /proc/self/ns/{user,pid,net,mnt})
host_cgroup=$(</proc/self/cgroup)
status=0
/usr/bin/bwrap \
    --unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts \
    --disable-userns --cap-drop ALL --new-session --die-with-parent --clearenv \
    --setenv PATH /usr/bin:/usr/sbin --setenv LC_ALL C --setenv TMPDIR /tmp \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin \
    --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    --ro-bind-try /etc/alternatives /etc/alternatives \
    "${fixture_mounts[@]}" \
    --ro-bind "$scratch/deny" /deny-power-command "${mounts[@]}" \
    --ro-bind "$test_dir/.." /pxeos --chdir /pxeos \
    --dir /run --bind "$scratch/tmp" /tmp \
    --proc /proc --remount-ro /proc --dev /dev --remount-ro / \
    -- /usr/bin/bash -eu -o pipefail -c '
        namespaces=$(readlink /proc/self/ns/{user,pid,net,mnt})
        paste <(printf "%s\n" "$1") <(printf "%s\n" "$namespaces") |
            awk "{if (NF != 2 || \$1 == \$2) bad=1} END {exit (bad || NR != 4)}"
        [[ $(</proc/self/cgroup) == "$2" ]]
        awk "/^Cap(Prm|Eff|Bnd|Amb):/ {if (\$2 != \"0000000000000000\") exit 1; checked++}
            END {if (checked != 4) exit 1}" /proc/self/status
        [[ -w /tmp && ! -w /pxeos && ! -w /proc/sysrq-trigger ]]
        [[ ! -e /run/systemd/private && ! -e /run/dbus/system_bus_socket &&
            ! -e /run/user && ! -e /sys && ! -e /home ]]
        [[ -z ${DBUS_SESSION_BUS_ADDRESS:-}${XDG_RUNTIME_DIR:-}${DISPLAY:-} ]]
        [[ -z $(find /dev -noleaf -type b -print) ]]
        shift 2

        for name in reboot poweroff shutdown halt telinit init systemctl loginctl busybox; do
            path=$(command -v "$name") || continue
            cmp -s "$path" /deny-power-command
            [[ $# -ne 0 ]] || printf "%s -> %s (deny stub)\n" "$name" "$(readlink -f -- "$path")"
        done
        if (( $# == 0 )); then
            printf "Isolated user/PID/network/mount namespaces:\n%s\n" "$namespaces"
            grep -E "^Cap(Prm|Eff|Bnd|Amb):" /proc/self/status
            printf "cgroup=%s; host buses absent; sysrq-trigger not writable; no block devices\n" "$(</proc/self/cgroup)"
            ls -l /dev
            exit
        fi
        export PXEOS_STARTUP_TEST_ISOLATED=1
        exec "$@"
    ' startup-isolation "$host_namespaces" "$host_cgroup" "${command[@]}" "$@" </dev/null || status=$?
if [[ -s $scratch/tmp/.unexpected-power-command ]]; then
    printf 'Unexpected command blocked in the PXEOS test sandbox:\n' >&2
    cat -- "$scratch/tmp/.unexpected-power-command" >&2
    exit 125
fi
exit "$status"
