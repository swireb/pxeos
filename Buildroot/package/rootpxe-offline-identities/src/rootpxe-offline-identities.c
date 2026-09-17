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

static int ascii_case_equal(const char *actual, const char *expected)
{
    size_t i;

    if (!actual || !expected)
        return 0;
    for (i = 0; actual[i] && expected[i]; i++) {
        unsigned char left = (unsigned char)actual[i];
        unsigned char right = (unsigned char)expected[i];

        if (left >= 'A' && left <= 'Z')
            left = (unsigned char)(left - 'A' + 'a');
        if (right >= 'A' && right <= 'Z')
            right = (unsigned char)(right - 'A' + 'a');
        if (left != right)
            return 0;
    }
    return !actual[i] && !expected[i];
}

static hive_node_h hostname_child_ci(hive_h *hive, hive_node_h parent,
                                     const char *expected, char **actual)
{
    hive_node_h *children;
    hive_node_h result = 0;
    size_t i;

    if (actual)
        *actual = NULL;
    children = hivex_node_children(hive, parent);
    if (!children)
        return 0;
    for (i = 0; children[i]; i++) {
        char *name = hivex_node_name(hive, children[i]);

        if (!name) {
            free(children);
            free(actual ? *actual : NULL);
            if (actual)
                *actual = NULL;
            return 0;
        }
        if (ascii_case_equal(name, expected)) {
            if (result) {
                free(name);
                free(children);
                free(actual ? *actual : NULL);
                if (actual)
                    *actual = NULL;
                return 0;
            }
            result = children[i];
            if (actual)
                *actual = name;
            else
                free(name);
            continue;
        }
        free(name);
    }
    free(children);
    return result;
}

static hive_value_h hostname_value_ci(hive_h *hive, hive_node_h parent,
                                      const char *expected, char **actual)
{
    hive_value_h *values;
    hive_value_h result = 0;
    size_t i;

    if (actual)
        *actual = NULL;
    values = hivex_node_values(hive, parent);
    if (!values)
        return 0;
    for (i = 0; values[i]; i++) {
        char *name = hivex_value_key(hive, values[i]);

        if (!name) {
            free(values);
            free(actual ? *actual : NULL);
            if (actual)
                *actual = NULL;
            return 0;
        }
        if (ascii_case_equal(name, expected)) {
            if (result) {
                free(name);
                free(values);
                free(actual ? *actual : NULL);
                if (actual)
                    *actual = NULL;
                return 0;
            }
            result = values[i];
            if (actual)
                *actual = name;
            else
                free(name);
            continue;
        }
        free(name);
    }
    free(values);
    return result;
}

static hive_node_h hostname_path_ci(hive_h *hive, hive_node_h start,
                                    const char *one, const char *two,
                                    const char *three, const char *four)
{
    const char *parts[] = {one, two, three, four, NULL};
    int i;

    for (i = 0; parts[i]; i++) {
        start = hostname_child_ci(hive, start, parts[i], NULL);
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

    value = hostname_value_ci(hive, node, key, NULL);
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

    value = node ? hostname_value_ci(hive, node, key, NULL) : 0;
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

    select = hostname_child_ci(hive, root, "Select", NULL);
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
            !hostname_child_ci(hive, root, control, NULL))
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

/* Emit reged paths only after proving every selected persistent field exists
 * as a REG_SZ.  Preserve the spelling stored in the offline hive for reged. */
static int windows_hostname_write_paths(const char *system)
{
    enum { max_paths = 6, path_size = 160 };
    hive_h *hive = NULL;
    hive_node_h root;
    unsigned selected[2];
    char paths[max_paths][path_size];
    size_t count, i, written = 0;

    if (!regular(system))
        return -1;
    hive = hivex_open(system, 0);
    if (!hive)
        return -1;
    root = hivex_root(hive);
    if (!root || selected_hostname_control_sets(hive, root, selected, &count))
        goto bad;
    for (i = 0; i < count; i++) {
        char expected_control[16];
        char *control_name = NULL, *services = NULL, *tcpip = NULL;
        char *parameters = NULL, *control = NULL, *computer_name = NULL;
        char *computer_key_name = NULL, *computer_value = NULL;
        char *hostname = NULL, *nv_hostname = NULL;
        hive_node_h control_set, tcp, computer_key;
        hive_value_h value;
        hive_type type;
        size_t size;
        unsigned char *data;

        if (written + 3 > max_paths ||
            snprintf(expected_control, sizeof(expected_control), "ControlSet%03u",
                     selected[i]) >= (int)sizeof(expected_control))
            goto bad_paths;
        control_set = hostname_child_ci(hive, root, expected_control, &control_name);
        tcp = control_set ? hostname_child_ci(hive, control_set, "Services", &services) : 0;
        tcp = tcp ? hostname_child_ci(hive, tcp, "Tcpip", &tcpip) : 0;
        tcp = tcp ? hostname_child_ci(hive, tcp, "Parameters", &parameters) : 0;
        computer_key = control_set ? hostname_child_ci(hive, control_set, "Control", &control) : 0;
        computer_key = computer_key ? hostname_child_ci(hive, computer_key, "ComputerName", &computer_name) : 0;
        computer_key = computer_key ? hostname_child_ci(hive, computer_key, "ComputerName", &computer_key_name) : 0;
        value = tcp ? hostname_value_ci(hive, tcp, "NV Hostname", &nv_hostname) : 0;
        data = value ? (unsigned char *)hivex_value_value(hive, value, &type, &size) : NULL;
        if (!data || type != hive_t_string) {
            free(data);
            goto bad_paths;
        }
        free(data);
        value = tcp ? hostname_value_ci(hive, tcp, "Hostname", &hostname) : 0;
        data = value ? (unsigned char *)hivex_value_value(hive, value, &type, &size) : NULL;
        if (!data || type != hive_t_string) {
            free(data);
            goto bad_paths;
        }
        free(data);
        value = computer_key ? hostname_value_ci(hive, computer_key, "ComputerName", &computer_value) : 0;
        data = value ? (unsigned char *)hivex_value_value(hive, value, &type, &size) : NULL;
        if (!data || type != hive_t_string || !control_name || !services || !tcpip ||
            !parameters || !control || !computer_name || !computer_key_name ||
            !computer_value || !hostname || !nv_hostname) {
            free(data);
            goto bad_paths;
        }
        free(data);
        if (snprintf(paths[written++], path_size, "\\%s\\%s\\%s\\%s\\%s",
                     control_name, services, tcpip, parameters, nv_hostname) >= path_size ||
            snprintf(paths[written++], path_size, "\\%s\\%s\\%s\\%s\\%s",
                     control_name, services, tcpip, parameters, hostname) >= path_size ||
            snprintf(paths[written++], path_size, "\\%s\\%s\\%s\\%s\\%s",
                     control_name, control, computer_name, computer_key_name,
                     computer_value) >= path_size)
            goto bad_paths;
        free(control_name); free(services); free(tcpip); free(parameters);
        free(control); free(computer_name); free(computer_key_name); free(computer_value);
        free(hostname); free(nv_hostname);
        continue;
bad_paths:
        free(control_name); free(services); free(tcpip); free(parameters);
        free(control); free(computer_name); free(computer_key_name); free(computer_value);
        free(hostname); free(nv_hostname);
        goto bad;
    }
    for (i = 0; i < written; i++)
        printf("%s\n", paths[i]);
    hivex_close(hive);
    return 0;
bad:
    fprintf(stderr, "offline SYSTEM hive hostname write paths are incomplete or unsafe\n");
    hivex_close(hive);
    return -1;
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
        current_set = hostname_child_ci(hive, root, control, NULL);
        if (!current_set)
            goto bad;
        if (!hostname) {
            printf("%s\n", control);
            continue;
        }
        tcp = hostname_path_ci(hive, current_set, "Services", "Tcpip",
                               "Parameters", NULL);
        computer = hostname_path_ci(hive, current_set, "Control", "ComputerName",
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
    if (argc == 3 && !strcmp(argv[1], "windows-hostname-write-paths"))
        return windows_hostname_write_paths(argv[2]) ? 1 : 0;
    if (argc == 4 && !strcmp(argv[1], "windows-hostname-verify"))
        return windows_hostname_inspect_or_verify(argv[2], argv[3]) ? 1 : 0;
    fprintf(stderr, "用法: %s windows-hostname-inspect SYSTEM | "
                    "windows-hostname-write-paths SYSTEM | "
                    "windows-hostname-verify SYSTEM HOSTNAME\n", argv[0]);
    return 2;
}
