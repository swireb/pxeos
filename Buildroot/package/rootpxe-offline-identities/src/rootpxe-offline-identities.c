/* RootPXE reads the offline SYSTEM hive before and after a hostname update.
 * This helper is deliberately read-only; reged remains the sole writer. */
#define _GNU_SOURCE
#include <hivex.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int regular(const char *path)
{
    struct stat status;

    return lstat(path, &status) == 0 && S_ISREG(status.st_mode) &&
           !S_ISLNK(status.st_mode);
}

static int le32(const unsigned char *value)
{
    return (int)value[0] | ((int)value[1] << 8) | ((int)value[2] << 16) |
           ((int)value[3] << 24);
}

static hive_node_h hostname_path(hive_h *hive, hive_node_h start,
                                 const char *one, const char *two,
                                 const char *three, const char *four)
{
    const char *parts[] = {one, two, three, four, NULL};
    int i;

    for (i = 0; parts[i]; i++) {
        start = hivex_node_get_child(hive, start, parts[i]);
        if (!start)
            return 0;
    }
    return start;
}

static int hostname_value_matches(hive_h *hive, hive_node_h node,
                                  const char *key, const char *hostname)
{
    hive_value_h value;
    hive_type type;
    size_t size, length, i;
    unsigned char *data;

    value = hivex_node_get_value(hive, node, key);
    if (!value)
        return -1;
    data = (unsigned char *)hivex_value_value(hive, value, &type, &size);
    length = strlen(hostname);
    if (!data || type != hive_t_string || size != (length + 1) * 2) {
        free(data);
        return -1;
    }
    for (i = 0; i < length; i++) {
        if (data[2 * i] != (unsigned char)hostname[i] || data[2 * i + 1]) {
            free(data);
            return -1;
        }
    }
    if (data[2 * length] || data[2 * length + 1]) {
        free(data);
        return -1;
    }
    free(data);
    return 0;
}

static int hostname_dword(hive_h *hive, hive_node_h node, const char *key,
                          unsigned *result)
{
    hive_value_h value;
    hive_type type;
    size_t size;
    unsigned char *data;

    value = node ? hivex_node_get_value(hive, node, key) : 0;
    data = value ? (unsigned char *)hivex_value_value(hive, value, &type,
                                                       &size)
                 : NULL;
    if (!data || type != hive_t_dword || size != 4) {
        free(data);
        return -1;
    }
    *result = (unsigned)le32(data);
    free(data);
    return *result == 0 || *result > 999 ? -1 : 0;
}

static int selected_hostname_control_sets(hive_h *hive, hive_node_h root,
                                          unsigned selected[2], size_t *count)
{
    hive_node_h select;
    char control[16];
    unsigned current;
    unsigned fallback;
    size_t i;

    select = hivex_node_get_child(hive, root, "Select");
    if (!select || hostname_dword(hive, select, "Current", &current) ||
        hostname_dword(hive, select, "Default", &fallback))
        return -1;
    selected[0] = current;
    *count = 1;
    if (fallback != current)
        selected[(*count)++] = fallback;
    for (i = 0; i < *count; i++) {
        if (snprintf(control, sizeof(control), "ControlSet%03u", selected[i])
                >= (int)sizeof(control) ||
            !hivex_node_get_child(hive, root, control))
            return -1;
    }
    return 0;
}

static int valid_windows_hostname(const char *hostname)
{
    size_t i;

    if (!hostname || !*hostname || strlen(hostname) > 15)
        return 0;
    for (i = 0; hostname[i]; i++) {
        if (!(hostname[i] == '-' || (hostname[i] >= 'A' && hostname[i] <= 'Z') ||
              (hostname[i] >= 'a' && hostname[i] <= 'z') ||
              (hostname[i] >= '0' && hostname[i] <= '9')))
            return 0;
    }
    return strspn(hostname, "0123456789") != strlen(hostname);
}

static int windows_hostname_inspect_or_verify(const char *system,
                                              const char *hostname)
{
    hive_h *hive = NULL;
    hive_node_h root;
    unsigned selected[2];
    size_t count;
    size_t i;

    if (!regular(system) || (hostname && !valid_windows_hostname(hostname)))
        return -1;
    hive = hivex_open(system, 0);
    if (!hive)
        return -1;
    root = hivex_root(hive);
    if (!root || selected_hostname_control_sets(hive, root, selected, &count))
        goto bad;
    for (i = 0; i < count; i++) {
        char control[16];
        hive_node_h current_set;
        hive_node_h tcp;
        hive_node_h computer;

        if (snprintf(control, sizeof(control), "ControlSet%03u", selected[i])
                >= (int)sizeof(control))
            goto bad;
        current_set = hivex_node_get_child(hive, root, control);
        if (!current_set)
            goto bad;
        if (!hostname) {
            printf("%s\n", control);
            continue;
        }
        tcp = hostname_path(hive, current_set, "Services", "Tcpip",
                            "Parameters", NULL);
        computer = hostname_path(hive, current_set, "Control", "ComputerName",
                                 "ComputerName", NULL);
        /* ActiveComputerName is volatile and is rebuilt on Windows boot.
         * It may be absent or stale in an offline SYSTEM hive. */
        if (!tcp || !computer ||
            hostname_value_matches(hive, tcp, "Hostname", hostname) ||
            hostname_value_matches(hive, tcp, "NV Hostname", hostname) ||
            hostname_value_matches(hive, computer, "ComputerName", hostname))
            goto bad;
    }
    hivex_close(hive);
    return 0;
bad:
    fprintf(stderr, "offline SYSTEM hive control-set or persistent hostname verification failed\n");
    hivex_close(hive);
    return -1;
}

int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "windows-hostname-inspect"))
        return windows_hostname_inspect_or_verify(argv[2], NULL) ? 1 : 0;
    if (argc == 4 && !strcmp(argv[1], "windows-hostname-verify"))
        return windows_hostname_inspect_or_verify(argv[2], argv[3]) ? 1 : 0;
    fprintf(stderr, "用法: %s windows-hostname-inspect SYSTEM | "
                    "windows-hostname-verify SYSTEM HOSTNAME\n", argv[0]);
    return 2;
}
