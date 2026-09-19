#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
lib="$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/multicast.sh"
jq_bin=${JQ_BIN:-jq}
if [[ $jq_bin != */* && $jq_bin != *\\* ]]; then
    jq_bin=$(command -v -- "$jq_bin") || { echo 'FAIL: jq is required' >&2; exit 1; }
fi
tmp=$(mktemp -d)
monitor_dir=''
trap 'rm -rf -- "$tmp" "${monitor_dir:-}"' EXIT
jq() { "$jq_bin" "$@"; }

curl() {
    local output=''
    printf '%s\n' "$@" >"$tmp/curl.args"
    while (( $# )); do
        case $1 in
            -o) output=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    printf '{"sessionId":"https-control","state":"WAITING"}\n' >"$output"
    printf '200'
}

. "$lib"
printf '{}' >"$tmp/request.json"

rootpxe_api=https://192.0.2.30:9443/service/pxeos/
rootpxe_multicast_http_post join "$tmp/request.json"
grep -Fqx -- '-k' "$tmp/curl.args" || { echo 'FAIL: HTTPS multicast request did not use curl -k' >&2; exit 1; }

rootpxe_api=http://192.0.2.30/service/pxeos/
rootpxe_multicast_http_post join "$tmp/request.json"
if grep -Fqx -- '-k' "$tmp/curl.args"; then
    echo 'FAIL: HTTP multicast request unexpectedly used curl -k' >&2
    exit 1
fi

rootpxe_multicast_operation_deadline=$SECONDS
if rootpxe_multicast_request_timeout; then
    echo 'FAIL: expired request deadline was accepted' >&2
    exit 1
fi
unset rootpxe_multicast_operation_deadline

secret='control-secret-must-not-log'
printf '{"code":"unexpected","error":"%s"}\n' "$secret" >"$tmp/response.json"
rootpxe_console_message() { printf '%s\n' "$*" >"$tmp/console.log"; }
rootpxe_multicast_http_failure join 500 7 "$tmp/response.json"
! grep -Fq -- "$secret" "$tmp/console.log" || { echo 'FAIL: multicast diagnostic leaked a secret' >&2; exit 1; }

unset -f curl
monitor_dir="/tmp/rootpxe-multicast-monitor.https-control.$$"
mkdir "$tmp/bin" "$monitor_dir"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$ROOTPXE_TEST_CURL_PID_FILE"
trap 'exit 0' TERM
while :; do sleep 1; done
EOF
chmod +x "$tmp/bin/curl"
export ROOTPXE_TEST_CURL_PID_FILE="$tmp/actual-curl.pid"
PATH="$tmp/bin:$PATH"
rootpxe_api=https://192.0.2.30:9443/service/pxeos/
rootpxe_multicast_http_dir="$monitor_dir"
set +e
rootpxe_multicast_http_post join "$tmp/request.json" &
post_pid=$!
set -e
for _ in {1..40}; do
    [[ -s $monitor_dir/curl.pid && -s $ROOTPXE_TEST_CURL_PID_FILE ]] && break
    sleep 0.05
done
[[ -s $monitor_dir/curl.pid && -s $ROOTPXE_TEST_CURL_PID_FILE ]] || { echo 'FAIL: asynchronous curl did not start' >&2; exit 1; }
read -r recorded_pid <"$monitor_dir/curl.pid"
read -r actual_pid <"$ROOTPXE_TEST_CURL_PID_FILE"
[[ $recorded_pid == "$actual_pid" ]] || { echo 'FAIL: pid_file did not record the real curl PID' >&2; exit 1; }
kill -TERM "$recorded_pid"
set +e
wait "$post_pid"
post_rc=$?
set -e
[[ $post_rc -ne 0 ]] || { echo 'FAIL: killed curl was reported successful' >&2; exit 1; }
[[ ! -e $monitor_dir/curl.pid ]] || { echo 'FAIL: pid_file was not cleaned after curl termination' >&2; exit 1; }

echo 'PASS: HTTPS RootPXE control requests preserve curl PID, timeout, and secret boundaries'
