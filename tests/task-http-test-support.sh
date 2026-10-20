#!/usr/bin/env bash
# curl mock 桥接：读取真实wrapper私有文件，再交给原fixture精确字段断言。
# 仅测试使用；不会调用网络。生产权限断言由各Linux/native回归单独负责。
. "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/task-http.sh"
task_http_test_decode_curl_args() {
    local argument value
    task_http_test_curl_args=()
    task_http_test_header_file=''
    while (( $# )); do
        argument=$1; shift
        case $argument in
            -q|--no-location) continue ;;
            --dump-header)
                task_http_test_header_file=$1
                printf 'HTTP/1.1 %s Fixture\r\n\r\n' "${TASK_HTTP_TEST_STATUS:-200}" >"$1"; shift; continue ;;
            --data-urlencode|--data-binary)
                value=$1; shift
                if [[ $argument == --data-urlencode && $value == token@* ]]; then value="token=$(command cat "${value#token@}")";
                elif [[ $argument == --data-binary && $value == @* && ${TASK_HTTP_TEST_EXPAND_JSON:-no} == yes ]]; then value=$(command cat "${value#@}"); fi
                task_http_test_curl_args+=("$argument" "$value"); continue ;;
        esac
        task_http_test_curl_args+=("$argument")
    done
}
export -f rootpxe_task_curl task_http_test_decode_curl_args
# Child-shell entry fixtures need the same multicast identity helpers that
# production funcs.sh sources; do not replace these safety checks with stubs.
export -f rootpxe_task_multicast_number_valid rootpxe_task_multicast_identity_valid rootpxe_task_multicast_form_args rootpxe_task_multicast_json
