/* Build a legal synthetic hive fixture from hivex's upstream minimal hive.
 * It deliberately contains only the records the offline repair tool owns. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <hivex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static void fail(const char *message)
{
    perror(message);
    exit(1);
}

static void put32(unsigned char *p, uint32_t value)
{
    p[0] = (unsigned char)value;
    p[1] = (unsigned char)(value >> 8);
    p[2] = (unsigned char)(value >> 16);
    p[3] = (unsigned char)(value >> 24);
}

static void put64(unsigned char *p, uint64_t value)
{
    int i;

    for (i = 0; i < 8; i++)
        p[i] = (unsigned char)(value >> (i * 8));
}

static void join_path(char *out, size_t out_size, const char *base,
                      const char *suffix)
{
    size_t base_len = strlen(base);
    size_t suffix_len = strlen(suffix);

    if (base_len > out_size - suffix_len - 1) {
        errno = ENAMETOOLONG;
        fail("fixture path");
    }
    memcpy(out, base, base_len);
    memcpy(out + base_len, suffix, suffix_len + 1);
}

static void copy_file(const char *source, const char *destination)
{
    int in = open(source, O_RDONLY | O_CLOEXEC);
    int out;
    unsigned char buffer[8192];
    ssize_t bytes;

    if (in < 0)
        fail("open minimal hive");
    out = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (out < 0)
        fail("create fixture hive");
    while ((bytes = read(in, buffer, sizeof(buffer))) > 0) {
        unsigned char *cursor = buffer;

        while (bytes) {
            ssize_t written = write(out, cursor, (size_t)bytes);

            if (written <= 0)
                fail("write fixture hive");
            cursor += written;
            bytes -= written;
        }
    }
    if (bytes < 0 || fsync(out) < 0)
        fail("copy fixture hive");
    if (close(in) < 0 || close(out) < 0)
        fail("close fixture hive");
}

static hive_node_h add_child(hive_h *hive, hive_node_h parent,
                             const char *name)
{
    hive_node_h node = hivex_node_add_child(hive, parent, name);

    if (!node)
        fail("add hive child");
    return node;
}

static void set_binary(hive_h *hive, hive_node_h node, const char *key,
                       unsigned char *value, size_t size)
{
    struct hive_set_value record = {
        .key = (char *)key,
        .t = hive_t_binary,
        .len = size,
        .value = (char *)value,
    };

    if (hivex_node_set_value(hive, node, &record, 0))
        fail("set hive value");
}

static void write_bcd(const char *path)
{
    /* BCD Element values prefix the device record with the owning object
     * GUID.  It is metadata, not part of the device record. */
    unsigned char record[16 + 0x48] = {0};
    unsigned char untouched[] = {0x52, 0x50, 0x58, 0x45};
    hive_h *hive = hivex_open(path, HIVEX_OPEN_WRITE);
    hive_node_h root;
    hive_node_h objects;
    hive_node_h object;
    hive_node_h elements;
    hive_node_h element;

    if (!hive)
        fail("open BCD hive");
    root = hivex_root(hive);
    objects = add_child(hive, root, "Objects");
    object = add_child(hive, objects, "{fixture-object}");
    elements = add_child(hive, object, "Elements");
    element = add_child(hive, elements, "11000001");
    memset(record, 0xa5, 16);
    put32(record + 16, 6);
    put32(record + 16 + 8, 0x48);
    put64(record + 16 + 0x10, 0x100000010ULL);
    put32(record + 16 + 0x24, 1);
    put32(record + 16 + 0x28, 0xf1234567U);
    set_binary(hive, element, "Element", record, sizeof(record));
    element = add_child(hive, elements, "22000001");
    set_binary(hive, element, "Element", untouched, sizeof(untouched));
    if (hivex_commit(hive, NULL, 0))
        fail("commit BCD hive");
    hivex_close(hive);
}

static void verify_value(hive_h *hive, hive_node_h node, const char *key,
                         const unsigned char *expected, size_t expected_size)
{
    hive_value_h value = hivex_node_get_value(hive, node, key);
    hive_type type;
    size_t size;
    unsigned char *data;

    if (!value)
        fail("missing fixture value");
    data = (unsigned char *)hivex_value_value(hive, value, &type, &size);
    if (!data || type != hive_t_binary || size != expected_size ||
        memcmp(data, expected, size)) {
        free(data);
        errno = EINVAL;
        fail("unexpected fixture value");
    }
    free(data);
}

static void verify_fixture(const char *root_path)
{
    char path[4096];
    unsigned char expected_bcd[16 + 0x48] = {0};
    unsigned char expected_system[12] = {0};
    unsigned char untouched[] = {0x52, 0x50, 0x58, 0x45};
    hive_h *hive;
    hive_node_h node;
    hive_node_h elements;
    FILE *xml;
    char xml_text[512];
    size_t bytes;

    memset(expected_bcd, 0xa5, 16);
    put32(expected_bcd + 16, 6);
    put32(expected_bcd + 16 + 8, 0x48);
    put64(expected_bcd + 16 + 0x10, 0x200000020ULL);
    put32(expected_bcd + 16 + 0x24, 1);
    put32(expected_bcd + 16 + 0x28, 10);
    join_path(path, sizeof(path), root_path, "/Boot/BCD");
    hive = hivex_open(path, 0);
    if (!hive)
        fail("open repaired BCD hive");
    node = hivex_node_get_child(hive, hivex_root(hive), "Objects");
    node = node ? hivex_node_get_child(hive, node, "{fixture-object}") : 0;
    node = node ? hivex_node_get_child(hive, node, "Elements") : 0;
    elements = node;
    node = node ? hivex_node_get_child(hive, node, "11000001") : 0;
    if (!node) {
        errno = EINVAL;
        fail("missing BCD device element");
    }
    verify_value(hive, node, "Element", expected_bcd, sizeof(expected_bcd));
    node = elements ? hivex_node_get_child(hive, elements, "22000001") : 0;
    if (!node) {
        errno = EINVAL;
        fail("missing unchanged BCD element");
    }
    verify_value(hive, node, "Element", untouched, sizeof(untouched));
    hivex_close(hive);

    put32(expected_system, 10);
    put64(expected_system + 4, 0x200000020ULL);
    join_path(path, sizeof(path), root_path, "/Windows/System32/config/SYSTEM");
    hive = hivex_open(path, 0);
    if (!hive)
        fail("open repaired SYSTEM hive");
    node = hivex_node_get_child(hive, hivex_root(hive), "MountedDevices");
    if (!node) {
        errno = EINVAL;
        fail("missing MountedDevices key");
    }
    verify_value(hive, node, "\\DosDevices\\C:", expected_system,
                 sizeof(expected_system));
    node = hivex_node_get_child(hive, hivex_root(hive), "ControlSet001");
    node = node ? hivex_node_get_child(hive, node, "Control") : 0;
    if (!node) {
        errno = EINVAL;
        fail("missing unchanged ControlSet fixture");
    }
    verify_value(hive, node, "Untouched", untouched, sizeof(untouched));
    hivex_close(hive);

    join_path(path, sizeof(path), root_path,
              "/Windows/System32/Recovery/ReAgent.xml");
    xml = fopen(path, "rb");
    if (!xml)
        fail("open repaired XML");
    bytes = fread(xml_text, 1, sizeof(xml_text) - 1, xml);
    fclose(xml);
    xml_text[bytes] = '\0';
    if (!strstr(xml_text,
                "WinreLocation guid=\"{12345678-9abc-def0-1122-334455667788}\"") ||
        !strstr(xml_text, "offset=\"8589934624\"") ||
        !strstr(xml_text,
                "WinreBCD id=\"{00112233-4455-6677-8899-aabbccddeeff}\"")) {
        errno = EINVAL;
        fail("unexpected repaired XML");
    }
}

static void write_system(const char *path)
{
    unsigned char record[12] = {0};
    unsigned char untouched[] = {0x52, 0x50, 0x58, 0x45};
    hive_h *hive = hivex_open(path, HIVEX_OPEN_WRITE);
    hive_node_h root;
    hive_node_h control_set;
    hive_node_h control;
    hive_node_h mounted_devices;

    if (!hive)
        fail("open SYSTEM hive");
    root = hivex_root(hive);
    mounted_devices = add_child(hive, root, "MountedDevices");
    control_set = add_child(hive, root, "ControlSet001");
    control = add_child(hive, control_set, "Control");
    set_binary(hive, control, "Untouched", untouched, sizeof(untouched));
    put32(record, 0xf1234567U);
    put64(record + 4, 0x100000010ULL);
    set_binary(hive, mounted_devices, "\\DosDevices\\C:", record,
               sizeof(record));
    if (hivex_commit(hive, NULL, 0))
        fail("commit SYSTEM hive");
    hivex_close(hive);
}

static void write_xml(const char *path)
{
    static const char document[] =
        "<WindowsRE><WinreBCD id=\"{00112233-4455-6677-8899-aabbccddeeff}\"/>"
        "<WinreLocation guid=\"{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}\" "
        "id=\"0\" offset=\"4294967312\"/>"
        "<ImageLocation guid=\"{00000000-0000-0000-0000-000000000000}\" "
        "id=\"0\" offset=\"0\"/>"
        "</WindowsRE>\n";
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);

    if (fd < 0 || write(fd, document, sizeof(document) - 1) !=
                      (ssize_t)(sizeof(document) - 1) ||
        fsync(fd) < 0 || close(fd) < 0)
        fail("write ReAgent XML");
}

int main(int argc, char **argv)
{
    char boot[4096];
    char config[4096];
    char recovery[4096];
    char path[4096];

    if (argc == 3 && !strcmp(argv[1], "--verify")) {
        verify_fixture(argv[2]);
        return 0;
    }
    if (argc != 3) {
        fprintf(stderr, "usage: %s MINIMAL_HIVE ROOT | --verify ROOT\n", argv[0]);
        return 2;
    }
    if (mkdir(argv[2], 0700) < 0 && errno != EEXIST)
        fail("create root");
    join_path(boot, sizeof(boot), argv[2], "/Boot");
    join_path(config, sizeof(config), argv[2], "/Windows/System32/config");
    join_path(recovery, sizeof(recovery), argv[2], "/Windows/System32/Recovery");
    if ((mkdir(boot, 0700) < 0 && errno != EEXIST) ||
        (mkdir(argv[2], 0700) < 0 && errno != EEXIST))
        fail("create fixture root");
    join_path(path, sizeof(path), argv[2], "/Windows");
    if (mkdir(path, 0700) < 0 && errno != EEXIST)
        fail("create Windows directory");
    join_path(path, sizeof(path), argv[2], "/Windows/System32");
    if (mkdir(path, 0700) < 0 && errno != EEXIST)
        fail("create System32 directory");
    if (mkdir(config, 0700) < 0 && errno != EEXIST)
        fail("create config directory");
    if (mkdir(recovery, 0700) < 0 && errno != EEXIST)
        fail("create recovery directory");
    join_path(path, sizeof(path), boot, "/BCD");
    copy_file(argv[1], path);
    write_bcd(path);
    join_path(path, sizeof(path), config, "/SYSTEM");
    copy_file(argv[1], path);
    write_system(path);
    join_path(path, sizeof(path), recovery, "/ReAgent.xml");
    write_xml(path);
    return 0;
}
