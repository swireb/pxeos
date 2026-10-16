#!/usr/bin/env bash
# Windows/MSYS cannot represent Linux chmod(0600), and ships no flock.
# These substitutes are test-only; native Linux validates the real contract.
if [[ -n ${root:-} && -n ${tmp:-} && -d $tmp ]]; then
    cp "$root/Buildroot/board/PXEOS/PXEOS/rootfs_overlay/usr/share/pxeos/lib/task-http.sh" "$tmp/task-http.sh"
fi
task_log_real_flock=$(type -P flock || true)
flock() {
    # Controlled sink failure is portable and is not proof of native lock
    # contention.  Outside injection, Linux still invokes its real flock.
    [[ ${TASK_LOG_TEST_LOCK_BUSY:-no} != yes ]] || return 1
    if [[ -n $task_log_real_flock ]]; then "$task_log_real_flock" "$@"; return $?; fi
    case ${OSTYPE:-} in
        cygwin*|msys*)
            if [[ $* == '-n -x 9' || $* == '-n -x 8' ]]; then return 0; fi
            command flock "$@" ;;
        *) printf 'Missing native flock for task-log regression.\n' >&2; return 127 ;;
    esac
}
task_log_test_load_helpers() {
    local source="$1" name paths
    paths="$(dirname "$source")/log-paths.sh"
    if [[ -r $paths ]]; then
        . <(sed "s|/tmp/log|${tmp:?private test directory required}/log|g" "$paths")
    fi
    while IFS= read -r name; do
        eval "$(sed -n "/^${name}() *{/,/^}/p" "$source" | sed "s|/tmp/log|${tmp:?}/log|g")"
    done < <(sed -nE 's/^((rootpxe_task_log_|rootpxe_run_logged_|rootpxe_task_console_|rootpxe_diagnostic_)[A-Za-z_0-9]*|rootpxe_redact_diagnostic|rootpxe_utf8_safe_prefix|rootpxe_utf8_safe_tail|rootpxe_bound_callback_message|rootpxe_console_message)\(\) *\{.*/\1/p' "$source")
    task_log_test_emulate_pin_flags
}

task_log_test_emulate_pin_flags() {
    case ${OSTYPE:-} in
        cygwin*|msys*)
            # MSYS has no /proc/self/fdinfo. This is an explicit tests-only
            # access-mode substitute, not Linux descriptor-flags evidence.
            rootpxe_log_pin_readonly() {
                rootpxe_log_pin_valid "${1:-}" "${2:-}" && [[ -O /proc/self/fd/$1 && ${TASK_LOG_TEST_NONREADONLY_FD:-} != "$1" ]]
            }
            ;;
    esac
}
case ${OSTYPE:-} in
    cygwin*|msys*)
        task_log_real_stat=$(type -P stat)
        stat() {
            local result
            result=$("$task_log_real_stat" "$@") || return $?
            case "$*" in
                */log|*/log/*|*/rootpxe-diagnostic.*|*/proc/self/fd/*)
                    case "$*" in
                        *'%d:%i:%a'*'/proc/self/fd/8') result=${result%:*}:700 ;;
                        *'%d:%i:%a'*'/log') result=${result%:*}:700 ;;
                        *'%a'*'/log') result=700 ;;
                        *%d:%i:%a*) result=${result%:*}:600 ;;
                        *%a*) result=600 ;;
                    esac ;;
            esac
            printf '%s\n' "$result"
        }
        printf 'NOTE: MSYS uses test-only POSIX mode/flock substitutes.\n' >&2
        ;;
esac
