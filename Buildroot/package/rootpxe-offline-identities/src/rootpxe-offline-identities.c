/* RootPXE offline Windows identity repair.  It deliberately edits only
 * copies during preflight: apply first verifies the saved originals have not
 * changed, then atomically installs every prepared file one at a time. */
#define _GNU_SOURCE
#include "efi-identities.h"

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <hivex.h>
#include <json-c/json.h>
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_ITEMS 96
#define MAX_MAPS 64

typedef struct {
    char mount[PATH_MAX];
    char table[8];
    char binding[PATH_MAX];
    char olddisk[64];
    char newdisk[64];
    char oldpart[64];
    char newpart[64];
    uint32_t partition;
    uint64_t oldoff;
    uint64_t newoff;
    uint64_t oldsize;
    uint64_t newsize;
    uint64_t oldsector;
    uint64_t newsector;
} map_t;

typedef struct {
    char root[PATH_MAX];
    char planid[80];
    char planhash[65];
    char state[PATH_MAX];
    char *manifest_json;
    char *plan_json;
    map_t map[MAX_MAPS];
    size_t nmap;
    char files[MAX_ITEMS][PATH_MAX];
    size_t nfiles;
    size_t nbcd;
    size_t nxml;
    size_t bcd_updates;
    size_t mounted_updates;
    size_t xml_updates;
} ctx_t;

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} json_buffer_t;

static const char *prog = "rootpxe-offline-identities";

static void die(const char *s)
{
    fprintf(stderr, "%s: %s\n", prog, s);
    exit(2);
}

static int le32(const unsigned char *p)
{
    return (int)p[0] | ((int)p[1] << 8) | ((int)p[2] << 16) |
           ((int)p[3] << 24);
}

static uint64_t le64(const unsigned char *p)
{
    uint64_t v = 0;
    int i;

    for (i = 7; i >= 0; i--)
        v = (v << 8) | p[i];
    return v;
}

static void put32(unsigned char *p, uint32_t v)
{
    p[0] = v;
    p[1] = v >> 8;
    p[2] = v >> 16;
    p[3] = v >> 24;
}

static void put64(unsigned char *p, uint64_t v)
{
    size_t i;

    for (i = 0; i < 8; i++)
        p[i] = (unsigned char)(v >> (8 * i));
}

static int regular(const char *p)
{
    struct stat s;

    return lstat(p, &s) == 0 && S_ISREG(s.st_mode) && !S_ISLNK(s.st_mode);
}

static int dir_ok(const char *p)
{
    struct stat s;

    return lstat(p, &s) == 0 && S_ISDIR(s.st_mode) && !S_ISLNK(s.st_mode);
}

static int prefix(const char *root, const char *p)
{
    size_t n = strlen(root);

    return !strncmp(root, p, n) && (p[n] == '/' || p[n] == '\0');
}

/* Input paths describe the mounted target and are part of the authorization
 * boundary.  Resolve them only after proving that no supplied component is a
 * symlink; otherwise a later replacement can redirect the repair outside the
 * reviewed target. */
static int no_symlink_components(const char *path)
{
    char checked[PATH_MAX];
    char *component;
    struct stat status;

    if (!path || path[0] != '/' || strlen(path) >= sizeof(checked))
        return -1;
    strcpy(checked, path);
    for (component = checked + 1; component;) {
        char *next = strchr(component, '/');

        if (next)
            *next = '\0';
        if (lstat(checked, &status) < 0 || S_ISLNK(status.st_mode))
            return -1;
        if (!next)
            break;
        *next = '/';
        component = next + 1;
        if (!*component)
            return -1;
    }
    return 0;
}

static int canonical_dir(const char *path, char out[PATH_MAX])
{
    char resolved[PATH_MAX];

    if (no_symlink_components(path) || !realpath(path, resolved) ||
        !dir_ok(resolved))
        return -1;
    memcpy(out, resolved, strlen(resolved) + 1);
    return 0;
}

static int canon_file(const char *p, char out[PATH_MAX])
{
    char resolved[PATH_MAX];

    if (no_symlink_components(p) || !realpath(p, resolved) ||
        !regular(resolved))
        return -1;
    memcpy(out, resolved, strlen(resolved) + 1);
    return 0;
}

static int join_path(char out[PATH_MAX], const char *base, const char *suffix)
{
    size_t base_len = strlen(base);
    size_t suffix_len = strlen(suffix);

    if (base_len > PATH_MAX - suffix_len - 1)
        return -1;
    memcpy(out, base, base_len);
    memcpy(out + base_len, suffix, suffix_len + 1);
    return 0;
}

static int staged_path(char out[PATH_MAX], const ctx_t *c, size_t index,
                       const char *extension)
{
    char suffix[32];
    int n;

    if (index >= MAX_ITEMS)
        return -1;
    n = snprintf(suffix, sizeof(suffix), "/%zu%s", index, extension);
    if (n < 0 || (size_t)n >= sizeof(suffix))
        return -1;
    return join_path(out, c->state, suffix);
}

static int copyfile(const char *a, const char *b)
{
    int in = -1;
    int out = -1;
    char buf[32768];
    ssize_t n;

    in = open(a, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (in < 0)
        goto bad;
    out = open(b, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (out < 0)
        goto bad;
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        char *q = buf;

        while (n) {
            ssize_t w = write(out, q, (size_t)n);

            if (w <= 0)
                goto bad;
            q += w;
            n -= w;
        }
    }
    if (n < 0 || fsync(out) < 0)
        goto bad;
    close(in);
    close(out);
    return 0;

bad:
    if (in >= 0)
        close(in);
    if (out >= 0)
        close(out);
    return -1;
}

static int samefile(const char *a, const char *b)
{
    int x = open(a, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int y = open(b, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    unsigned char p[32768];
    unsigned char q[32768];
    ssize_t n;
    ssize_t m;

    if (x < 0 || y < 0)
        goto no;
    for (;;) {
        n = read(x, p, sizeof(p));
        m = read(y, q, sizeof(q));
        if (n < 0 || m < 0 || n != m || (n && memcmp(p, q, (size_t)n)))
            goto no;
        if (!n)
            break;
    }
    close(x);
    close(y);
    return 1;

no:
    if (x >= 0)
        close(x);
    if (y >= 0)
        close(y);
    return 0;
}

static int same_string_file(const char *path, const char *expected)
{
    int fd;
    char buffer[4096];
    size_t offset = 0;
    size_t length = strlen(expected);
    ssize_t bytes;

    if (!regular(path))
        return 0;
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return 0;
    while ((bytes = read(fd, buffer, sizeof(buffer))) > 0) {
        if ((size_t)bytes > length - offset ||
            memcmp(buffer, expected + offset, (size_t)bytes)) {
            close(fd);
            return 0;
        }
        offset += (size_t)bytes;
    }
    close(fd);
    return bytes == 0 && offset == length;
}

static int write_string_file(const char *path, const char *contents)
{
    int fd;
    size_t length = strlen(contents);
    size_t offset = 0;

    fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
              0600);
    if (fd < 0)
        return -1;
    while (offset < length) {
        ssize_t written = write(fd, contents + offset, length - offset);

        if (written <= 0) {
            close(fd);
            return -1;
        }
        offset += (size_t)written;
    }
    if (fsync(fd) < 0 || close(fd) < 0)
        return -1;
    return 0;
}

static int clean_hive(const char *p)
{
    unsigned char h[12];
    int fd = open(p, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    ssize_t n;

    if (fd < 0)
        return 0;
    n = read(fd, h, sizeof(h));
    close(fd);
    /* Equal base sequence numbers mean this hive is clean.  LOG1/LOG2 may
     * legitimately remain after a clean Windows shutdown; unequal numbers
     * need transaction-log replay, which this implementation refuses. */
    return n == (ssize_t)sizeof(h) && !memcmp(h, "regf", 4) &&
           le32(h + 4) == le32(h + 8);
}

static int atomic_install(const char *src, const char *dst)
{
    char tmp[PATH_MAX];
    int fd;

    if (join_path(tmp, dst, ".rootpxe-new"))
        return -1;
    unlink(tmp);
    if (copyfile(src, tmp))
        return -1;
    fd = open(tmp, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0 || fsync(fd) < 0) {
        if (fd >= 0)
            close(fd);
        unlink(tmp);
        return -1;
    }
    close(fd);
    if (rename(tmp, dst) < 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

static int guid_bytes(const char *s, unsigned char b[16])
{
    unsigned x[16];
    int i;

    if (strlen(s) != 36 ||
        sscanf(s,
               "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x",
               &x[0], &x[1], &x[2], &x[3], &x[4], &x[5], &x[6], &x[7],
               &x[8], &x[9], &x[10], &x[11], &x[12], &x[13], &x[14],
               &x[15]) != 16)
        return -1;
    b[0] = x[3];
    b[1] = x[2];
    b[2] = x[1];
    b[3] = x[0];
    b[4] = x[5];
    b[5] = x[4];
    b[6] = x[7];
    b[7] = x[6];
    for (i = 8; i < 16; i++)
        b[i] = x[i];
    return 0;
}

static int json_string(json_object *o, const char *k, char *out, size_t z,
                       int needed)
{
    json_object *v;
    const char *s;

    if (!json_object_object_get_ex(o, k, &v))
        return needed ? -1 : 0;
    if (!json_object_is_type(v, json_type_string))
        return -1;
    s = json_object_get_string(v);
    if (strlen(s) >= z)
        return -1;
    strcpy(out, s);
    return 0;
}

static int json_u64(json_object *o, const char *k, uint64_t *out)
{
    json_object *v;

    if (!json_object_object_get_ex(o, k, &v) ||
        !json_object_is_type(v, json_type_int))
        return -1;
    *out = (uint64_t)json_object_get_int64(v);
    return 0;
}

static int json_u32(json_object *o, const char *k, uint32_t *out)
{
    uint64_t value;

    if (json_u64(o, k, &value) || !value || value > UINT32_MAX)
        return -1;
    *out = (uint32_t)value;
    return 0;
}

static int json_array(json_object *o, const char *k, json_object **out)
{
    return !json_object_object_get_ex(o, k, out) ||
           !json_object_is_type(*out, json_type_array)
               ? -1
               : 0;
}

static int json_object_value(json_object *o, const char *k, json_object **out)
{
    return !json_object_object_get_ex(o, k, out) ||
           !json_object_is_type(*out, json_type_object)
               ? -1
               : 0;
}

static int json_string_equal(json_object *o, const char *k, const char *value)
{
    char actual[PATH_MAX];

    return json_string(o, k, actual, sizeof(actual), 1) ||
                   strcmp(actual, value)
               ? -1
               : 0;
}

static int json_buffer_append(json_buffer_t *buffer, const char *data,
                              size_t length)
{
    size_t capacity;
    char *grown;

    if (length > SIZE_MAX - buffer->length - 1)
        return -1;
    if (buffer->length + length + 1 > buffer->capacity) {
        capacity = buffer->capacity ? buffer->capacity : 128;
        while (capacity < buffer->length + length + 1) {
            if (capacity > SIZE_MAX / 2)
                return -1;
            capacity *= 2;
        }
        grown = realloc(buffer->data, capacity);
        if (!grown)
            return -1;
        buffer->data = grown;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->length, data, length);
    buffer->length += length;
    buffer->data[buffer->length] = '\0';
    return 0;
}

static int string_compare(const void *left, const void *right)
{
    const char *const *a = left;
    const char *const *b = right;

    return strcmp(*a, *b);
}

static int canonical_json_value(json_object *value, json_buffer_t *buffer)
{
    const char *serialized;
    enum json_type type;
    size_t count;
    size_t i;

    if (!value)
        return json_buffer_append(buffer, "null", 4);
    type = json_object_get_type(value);
    if (type == json_type_array) {
        count = json_object_array_length(value);
        if (json_buffer_append(buffer, "[", 1))
            return -1;
        for (i = 0; i < count; i++) {
            if ((i && json_buffer_append(buffer, ",", 1)) ||
                canonical_json_value(json_object_array_get_idx(value, (int)i),
                                     buffer))
                return -1;
        }
        return json_buffer_append(buffer, "]", 1);
    }
    if (type == json_type_object) {
        const char **keys;
        json_object *member;

        count = json_object_object_length(value);
        keys = calloc(count ? count : 1, sizeof(*keys));
        if (!keys)
            return -1;
        i = 0;
        json_object_object_foreach(value, name, ignored) {
            (void)ignored;
            keys[i++] = name;
        }
        qsort(keys, count, sizeof(*keys), string_compare);
        if (json_buffer_append(buffer, "{", 1)) {
            free(keys);
            return -1;
        }
        for (i = 0; i < count; i++) {
            json_object *quoted = json_object_new_string(keys[i]);

            if (!quoted || !json_object_object_get_ex(value, keys[i], &member)) {
                if (quoted)
                    json_object_put(quoted);
                free(keys);
                return -1;
            }
            serialized = json_object_to_json_string_ext(quoted,
                                                         JSON_C_TO_STRING_PLAIN);
            if ((i && json_buffer_append(buffer, ",", 1)) ||
                json_buffer_append(buffer, serialized, strlen(serialized)) ||
                json_buffer_append(buffer, ":", 1) ||
                canonical_json_value(member, buffer)) {
                json_object_put(quoted);
                free(keys);
                return -1;
            }
            json_object_put(quoted);
        }
        free(keys);
        return json_buffer_append(buffer, "}", 1);
    }
    serialized = json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN);
    return json_buffer_append(buffer, serialized, strlen(serialized));
}

static char *canonical_json(json_object *value)
{
    json_buffer_t buffer = {0};

    if (canonical_json_value(value, &buffer)) {
        free(buffer.data);
        return NULL;
    }
    return buffer.data;
}

static int valid_plan_hash(const char *hash)
{
    return strlen(hash) == 64 &&
           strspn(hash, "0123456789abcdef") == strlen(hash);
}

static int valid_mbr_id(const char *id)
{
    unsigned value;
    char rest;

    return sscanf(id, "%8x%c", &value, &rest) == 1 && strlen(id) == 8;
}

static int add_file(ctx_t *c, const char *p)
{
    char x[PATH_MAX];
    size_t i;

    if (c->nfiles == MAX_ITEMS || canon_file(p, x))
        return -1;
    for (i = 0; i < c->nfiles; i++) {
        if (!strcmp(c->files[i], x))
            return 0;
    }
    strcpy(c->files[c->nfiles++], x);
    return 0;
}

static int volume_allowed(ctx_t *c, const char *p)
{
    size_t i;

    for (i = 0; i < c->nmap; i++) {
        if (prefix(c->map[i].mount, p))
            return 1;
    }
    return 0;
}

static int plan_disk_for_topology(json_object *disks, json_object *old_disk,
                                  json_object **out)
{
    json_object *candidate;
    char target[PATH_MAX];
    int found = 0;
    size_t i;

    if (json_string(old_disk, "targetDevice", target, sizeof(target), 1))
        return -1;
    for (i = 0; i < json_object_array_length(disks); i++) {
        candidate = json_object_array_get_idx(disks, (int)i);
        if (!json_object_is_type(candidate, json_type_object))
            return -1;
        if (!json_string_equal(candidate, "targetDevice", target)) {
            if (found++)
                return -1;
            *out = candidate;
        }
    }
    return found == 1 ? 0 : -1;
}

static int map_matches_plan(map_t *map, json_object *topology_disks,
                            json_object *plan_disks)
{
    json_object *old_disk;
    json_object *new_disk;
    json_object *old_parts;
    json_object *new_parts;
    json_object *old_part;
    json_object *new_part;
    char expected[PATH_MAX];
    char old_target[PATH_MAX];
    char partition_guid[64];
    int disk_matches = 0;
    int part_matches = 0;
    size_t i;
    size_t j;
    size_t k;
    uint32_t number;

    for (i = 0; i < json_object_array_length(topology_disks); i++) {
        old_disk = json_object_array_get_idx(topology_disks, (int)i);
        if (!json_object_is_type(old_disk, json_type_object) ||
            json_string_equal(old_disk, "targetBinding", map->binding) ||
            json_string_equal(old_disk, "partitionTable", map->table) ||
            json_string_equal(old_disk, "oldDiskId", map->olddisk) ||
            plan_disk_for_topology(plan_disks, old_disk, &new_disk))
            continue;
        if (disk_matches++)
            return -1;
        if (json_string_equal(new_disk, "partitionTable", map->table) ||
            json_string(new_disk,
                        !strcmp(map->table, "gpt") ? "diskGuid"
                                                    : "diskSignature",
                        expected, sizeof(expected), 1) ||
            strcmp(expected, map->newdisk) || json_array(old_disk, "partitions",
                                                          &old_parts) ||
            json_array(new_disk, "partitions", &new_parts))
            return -1;
        for (j = 0; j < json_object_array_length(old_parts); j++) {
            old_part = json_object_array_get_idx(old_parts, (int)j);
            if (!json_object_is_type(old_part, json_type_object) ||
                json_u32(old_part, "number", &number) ||
                number != map->partition ||
                json_string_equal(old_part, "oldPartitionId", map->oldpart) ||
                json_string(old_part, "targetDevice", old_target,
                            sizeof(old_target), 1))
                continue;
            for (k = 0; k < json_object_array_length(new_parts); k++) {
                new_part = json_object_array_get_idx(new_parts, (int)k);
                partition_guid[0] = '\0';
                if (!json_object_is_type(new_part, json_type_object) ||
                    json_string_equal(new_part, "targetDevice", old_target) ||
                    (!strcmp(map->table, "gpt") &&
                     json_string_equal(new_part, "partitionGuid", map->newpart)) ||
                    (!strcmp(map->table, "mbr") &&
                     (json_string(new_part, "partitionGuid", partition_guid,
                                  sizeof(partition_guid), 0) ||
                      partition_guid[0])))
                    continue;
                if (part_matches++)
                    return -1;
            }
        }
    }
    return disk_matches == 1 && part_matches == 1 ? 0 : -1;
}

static int map_is_duplicate(ctx_t *c, size_t current)
{
    size_t i;

    for (i = 0; i < current; i++) {
        if (!strcmp(c->map[i].binding, c->map[current].binding) &&
            c->map[i].partition == c->map[current].partition)
            return 1;
    }
    return 0;
}

static int remember_inputs(ctx_t *c, json_object *manifest, json_object *plan,
                           json_object *plan_hash)
{
    json_object *identity;
    c->manifest_json = canonical_json(manifest);
    if (!c->manifest_json)
        return -1;
    identity = json_object_new_object();
    if (!identity)
        return -1;
    json_object_object_add(identity, "plan", json_object_get(plan));
    json_object_object_add(identity, "planHash", json_object_get(plan_hash));
    c->plan_json = canonical_json(identity);
    json_object_put(identity);
    return c->plan_json ? 0 : -1;
}

static int read_manifest(ctx_t *c, const char *manifest, const char *plan)
{
    json_object *m = json_object_from_file(manifest);
    json_object *p = json_object_from_file(plan);
    json_object *a;
    json_object *v;
    json_object *d;
    json_object *topology;
    json_object *topology_disks;
    json_object *plan_disks;
    json_object *plan_hash;
    char state_base[PATH_MAX];
    char state_parent[PATH_MAX];
    size_t i;

    if (!m || !p)
        goto bad;
    if (!json_object_is_type(m, json_type_object) ||
        !json_object_is_type(p, json_type_object) ||
        json_object_get_int(json_object_object_get(m, "version")) != 1 ||
        json_object_get_int(json_object_object_get(p, "attempt")) < 1 ||
        !json_object_object_get_ex(p, "planHash", &plan_hash) ||
        json_string(p, "planHash", c->planhash, sizeof(c->planhash), 1) ||
        !valid_plan_hash(c->planhash) || json_object_value(p, "plan", &d) ||
        json_object_get_int(json_object_object_get(d, "version")) != 1 ||
        json_object_value(d, "topology", &topology) ||
        json_array(topology, "disks", &topology_disks) ||
        json_array(d, "disks", &plan_disks))
        goto bad;
    if (json_string(m, "windowsRoot", c->root, sizeof(c->root), 1) ||
        canonical_dir(c->root, c->root))
        goto bad;
    if (json_string(d, "planId", c->planid, sizeof(c->planid), 1) ||
        !c->planid[0] || !strcmp(c->planid, ".") ||
        !strcmp(c->planid, "..") || strspn(c->planid,
               "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-") !=
            strlen(c->planid))
        goto bad;
    if (join_path(state_parent, c->root, "/.rootpxe-offline-identities") ||
        join_path(state_base, state_parent, "/") ||
        join_path(c->state, state_base, c->planid))
        goto bad;
    if (json_array(m, "volumes", &a) || !json_object_array_length(a))
        goto bad;
    for (i = 0; i < (size_t)json_object_array_length(a); i++) {
        v = json_object_array_get_idx(a, (int)i);
        if (!json_object_is_type(v, json_type_object) || c->nmap == MAX_MAPS ||
            json_string(v, "mount", c->map[c->nmap].mount, PATH_MAX, 1) ||
            canonical_dir(c->map[c->nmap].mount, c->map[c->nmap].mount) ||
            json_string(v, "partitionTable", c->map[c->nmap].table,
                        sizeof(c->map[c->nmap].table), 1) ||
            json_string(v, "diskBinding", c->map[c->nmap].binding,
                        sizeof(c->map[c->nmap].binding), 1) ||
            json_u32(v, "partitionNumber", &c->map[c->nmap].partition) ||
            json_string(v, "oldDiskId", c->map[c->nmap].olddisk,
                        sizeof(c->map[c->nmap].olddisk), 1) ||
            json_string(v, "newDiskId", c->map[c->nmap].newdisk,
                        sizeof(c->map[c->nmap].newdisk), 1) ||
            json_string(v, "oldPartitionGuid", c->map[c->nmap].oldpart,
                        sizeof(c->map[c->nmap].oldpart), 1) ||
            json_string(v, "newPartitionGuid", c->map[c->nmap].newpart,
                        sizeof(c->map[c->nmap].newpart), 1) ||
            json_u64(v, "oldOffsetBytes", &c->map[c->nmap].oldoff) ||
            json_u64(v, "newOffsetBytes", &c->map[c->nmap].newoff) ||
            json_u64(v, "oldSizeBytes", &c->map[c->nmap].oldsize) ||
            json_u64(v, "newSizeBytes", &c->map[c->nmap].newsize) ||
            json_u64(v, "oldLogicalSectorBytes", &c->map[c->nmap].oldsector) ||
            json_u64(v, "newLogicalSectorBytes", &c->map[c->nmap].newsector) ||
            !c->map[c->nmap].oldsize || !c->map[c->nmap].newsize ||
            !c->map[c->nmap].oldsector || !c->map[c->nmap].newsector ||
            (strcmp(c->map[c->nmap].table, "mbr") &&
             strcmp(c->map[c->nmap].table, "gpt")))
            goto bad;
        if ((!strcmp(c->map[c->nmap].table, "gpt") &&
             (guid_bytes(c->map[c->nmap].olddisk, (unsigned char[16]){0}) ||
              guid_bytes(c->map[c->nmap].newdisk, (unsigned char[16]){0}) ||
              guid_bytes(c->map[c->nmap].oldpart, (unsigned char[16]){0}) ||
              guid_bytes(c->map[c->nmap].newpart, (unsigned char[16]){0}))) ||
            (!strcmp(c->map[c->nmap].table, "mbr") &&
             (!valid_mbr_id(c->map[c->nmap].olddisk) ||
              !valid_mbr_id(c->map[c->nmap].newdisk))) ||
            map_is_duplicate(c, c->nmap) ||
            map_matches_plan(&c->map[c->nmap], topology_disks, plan_disks))
            goto bad;
        c->nmap++;
    }
    if (!c->nmap)
        goto bad;
    if (json_array(m, "bcdStores", &a) ||
        json_object_array_length(a) < 1)
        goto bad;
    for (i = 0; i < (size_t)json_object_array_length(a); i++) {
        v = json_object_array_get_idx(a, (int)i);
        if (!json_object_is_type(v, json_type_string) ||
            add_file(c, json_object_get_string(v)))
            goto bad;
    }
    c->nbcd = c->nfiles;
    if (!json_object_object_get_ex(m, "systemHive", &v) ||
        !json_object_is_type(v, json_type_string) || add_file(c, json_object_get_string(v)))
        goto bad;
    if (json_array(m, "reAgentXml", &a))
        goto bad;
    for (i = 0; i < (size_t)json_object_array_length(a); i++) {
        v = json_object_array_get_idx(a, (int)i);
        if (!json_object_is_type(v, json_type_string) ||
            add_file(c, json_object_get_string(v)))
            goto bad;
    }
    c->nxml = c->nfiles - c->nbcd - 1;
    for (i = 0; i < c->nfiles; i++) {
        if (!volume_allowed(c, c->files[i]))
            goto bad;
    }
    if (remember_inputs(c, m, d, plan_hash))
        goto bad;
    json_object_put(m);
    json_object_put(p);
    return 0;

bad:
    if (m)
        json_object_put(m);
    if (p)
        json_object_put(p);
    return -1;
}
/* 0 means no mapping, 1 means exactly one mapping and -1 means an unsafe
 * ambiguity.  A first-match repair can silently retarget boot state. */
static int mbrmap(ctx_t *c, uint32_t signature, uint64_t offset, map_t **out)
{
    size_t i;
    unsigned old_signature;
    map_t *found = NULL;

    for (i = 0; i < c->nmap; i++) {
        if (!strcmp(c->map[i].table, "mbr") &&
            sscanf(c->map[i].olddisk, "%x", &old_signature) == 1 &&
            old_signature == signature && c->map[i].oldoff == offset) {
            if (found)
                return -1;
            found = &c->map[i];
        }
    }
    *out = found;
    return found ? 1 : 0;
}

static int gptmap(ctx_t *c, const unsigned char *disk,
                  const unsigned char *part, map_t **out)
{
    size_t i;
    unsigned char old_disk[16];
    unsigned char old_part[16];
    map_t *found = NULL;

    for (i = 0; i < c->nmap; i++) {
        if (!strcmp(c->map[i].table, "gpt") &&
            !guid_bytes(c->map[i].olddisk, old_disk) &&
            !guid_bytes(c->map[i].oldpart, old_part) &&
            !memcmp(old_disk, disk, sizeof(old_disk)) &&
            !memcmp(old_part, part, sizeof(old_part))) {
            if (found)
                return -1;
            found = &c->map[i];
        }
    }
    *out = found;
    return found ? 1 : 0;
}

static int device_element(hive_h *hive, hive_node_h node)
{
    char *name = hivex_node_name(hive, node);
    char *end;
    unsigned long value;
    int result = 0;

    if (!name)
        return -1;
    errno = 0;
    value = strtoul(name, &end, 16);
    if (!errno && *name && !*end && strlen(name) == 8 &&
        (value & 0x0f000000UL) == 0x01000000UL)
        result = 1;
    free(name);
    return result;
}

static int fix_record(ctx_t *c, unsigned char *record, size_t size, int depth,
                      int *changed)
{
    uint32_t type;
    uint32_t length;
    uint32_t style;
    uint32_t signature;
    map_t *map;
    unsigned char disk[16];
    unsigned char part[16];

    if (depth > 8 || size < 16)
        return -1;
    type = (uint32_t)le32(record);
    length = (uint32_t)le32(record + 8);
    if (length < 16 || length > size)
        return -1;
    if (type == 5)
        return 0;
    if (type == 0) {
        if (length < 0x34 + 16)
            return -1;
        return fix_record(c, record + 0x34, length - 0x34, depth + 1,
                          changed);
    }
    if (type != 6 || length != 0x48)
        return -1;
    style = (uint32_t)le32(record + 0x24);
    if (style == 0) {
        memcpy(part, record + 0x10, sizeof(part));
        memcpy(disk, record + 0x28, sizeof(disk));
        if (gptmap(c, disk, part, &map) < 0)
            return -1;
        if (!map)
            return 0;
        if (guid_bytes(map->newpart, part) || guid_bytes(map->newdisk, disk))
            return -1;
        memcpy(record + 0x10, part, sizeof(part));
        memcpy(record + 0x28, disk, sizeof(disk));
        *changed = 1;
        return 0;
    }
    if (style == 1) {
        signature = (uint32_t)le32(record + 0x28);
        if (mbrmap(c, signature, le64(record + 0x10), &map) < 0)
            return -1;
        if (!map)
            return 0;
        if (sscanf(map->newdisk, "%x", &signature) != 1)
            return -1;
        put64(record + 0x10, map->newoff);
        put32(record + 0x28, signature);
        *changed = 1;
        return 0;
    }
    return -1;
}
static int bcd_file(ctx_t *c, const char *path)
{
    hive_h *hive;
    hive_node_h objects;
    hive_node_h elements;
    hive_node_h *objects_list = NULL;
    hive_node_h *elements_list = NULL;
    hive_value_h value;
    hive_type type;
    size_t i;
    size_t j;
    size_t size;
    unsigned char *data;
    char *key;
    int changed = 0;
    int device;

    hive = hivex_open(path, HIVEX_OPEN_WRITE);
    if (!hive)
        return -1;
    objects = hivex_node_get_child(hive, hivex_root(hive), "Objects");
    if (!objects)
        goto bad;
    objects_list = hivex_node_children(hive, objects);
    if (!objects_list)
        goto bad;
    for (i = 0; objects_list[i]; i++) {
        elements = hivex_node_get_child(hive, objects_list[i], "Elements");
        if (!elements)
            continue;
        elements_list = hivex_node_children(hive, elements);
        if (!elements_list)
            goto bad;
        for (j = 0; elements_list[j]; j++) {
            device = device_element(hive, elements_list[j]);
            if (device < 0)
                goto bad;
            if (!device)
                continue;
            value = hivex_node_get_value(hive, elements_list[j], "Element");
            if (!value)
                goto bad;
            data = (unsigned char *)hivex_value_value(hive, value, &type, &size);
            if (!data || type != hive_t_binary || size < 16 ||
                fix_record(c, data + 16, size - 16, 0, &changed)) {
                free(data);
                goto bad;
            }
            if (changed) {
                struct hive_set_value replacement;

                key = hivex_value_key(hive, value);
                if (!key) {
                    free(data);
                    goto bad;
                }
                replacement.key = key;
                replacement.t = type;
                replacement.len = size;
                replacement.value = (char *)data;
                if (hivex_node_set_value(hive, elements_list[j], &replacement,
                                         0)) {
                    free(key);
                    free(data);
                    goto bad;
                }
                free(key);
                changed = 0;
                c->bcd_updates++;
            }
            free(data);
        }
        free(elements_list);
        elements_list = NULL;
    }
    free(objects_list);
    objects_list = NULL;
    if (hivex_commit(hive, NULL, 0))
        goto bad;
    hivex_close(hive);
    return 0;

bad:
    free(elements_list);
    free(objects_list);
    hivex_close(hive);
    return -1;
}
static int mounted_file(ctx_t *c, const char *path)
{
    hive_h *hive;
    hive_node_h root;
    hive_node_h mounted_devices;
    hive_value_h *values = NULL;
    size_t j;
    size_t size;
    char *key;
    hive_type type;
    unsigned char *data;
    int updated = 0;

    hive = hivex_open(path, HIVEX_OPEN_WRITE);
    if (!hive)
        return -1;
    root = hivex_root(hive);
    /* MountedDevices is a direct SYSTEM-root key.  ControlSet is unrelated
     * configuration state and must stay untouched. */
    mounted_devices = hivex_node_get_child(hive, root, "MountedDevices");
    if (!mounted_devices)
        goto bad;
    values = hivex_node_values(hive, mounted_devices);
    if (!values)
        goto bad;
    for (j = 0; values[j]; j++) {
            data = (unsigned char *)hivex_value_value(hive, values[j], &type,
                                                       &size);
            key = hivex_value_key(hive, values[j]);
            if (!data || !key) {
                free(data);
                free(key);
                goto bad;
            }
            if (type == hive_t_binary && size == 12) {
                map_t *map = NULL;
                int mapped = mbrmap(c, (uint32_t)le32(data), le64(data + 4),
                                    &map);

                if (mapped < 0) {
                    free(data);
                    free(key);
                    goto bad;
                }
                if (map) {
                    unsigned signature;
                    struct hive_set_value replacement;

                    if (sscanf(map->newdisk, "%x", &signature) != 1) {
                        free(data);
                        free(key);
                        goto bad;
                    }
                    put32(data, signature);
                    put64(data + 4, map->newoff);
                    replacement.key = key;
                    replacement.t = type;
                    replacement.len = size;
                    replacement.value = (char *)data;
                    if (hivex_node_set_value(hive, mounted_devices,
                                             &replacement, 0)) {
                        free(data);
                        free(key);
                        goto bad;
                    }
                    updated = 1;
                    c->mounted_updates++;
                }
            } else if (type == hive_t_binary && size == 24 &&
                       !memcmp(data, "DMIO:ID:", 8)) {
                size_t map_index;
                map_t *match = NULL;

                for (map_index = 0; map_index < c->nmap; map_index++) {
                    unsigned char old_guid[16];
                    map_t *map = &c->map[map_index];

                    if (strcmp(map->table, "gpt") ||
                        guid_bytes(map->oldpart, old_guid) ||
                        memcmp(old_guid, data + 8, sizeof(old_guid)))
                        continue;
                    if (match) {
                        free(data);
                        free(key);
                        goto bad;
                    }
                    match = map;
                }
                if (match) {
                    unsigned char new_guid[16];

                    if (guid_bytes(match->newpart, new_guid)) {
                        free(data);
                        free(key);
                        goto bad;
                    }
                    memcpy(data + 8, new_guid, sizeof(new_guid));
                    {
                        struct hive_set_value replacement = {
                            .key = key,
                            .t = type,
                            .len = size,
                            .value = (char *)data,
                        };

                        if (hivex_node_set_value(hive, mounted_devices,
                                                 &replacement, 0)) {
                            free(data);
                            free(key);
                            goto bad;
                        }
                    }
                    updated = 1;
                    c->mounted_updates++;
                }
            }
            free(data);
            free(key);
    }
    free(values);
    values = NULL;
    if (hivex_commit(hive, NULL, 0))
        goto bad;
    hivex_close(hive);
    return updated ? 0 : -1;

bad:
    free(values);
    hivex_close(hive);
    return -1;
}
static xmlNode *child(xmlNode *node, const char *name)
{
    xmlNode *current;

    for (current = node ? node->children : NULL; current;
         current = current->next) {
        if (current->type == XML_ELEMENT_NODE &&
            !xmlStrcasecmp(current->name, (const xmlChar *)name))
            return current;
    }
    return NULL;
}
static int xml_guid_matches(const char *value, const char *guid)
{
    size_t length;

    if (!value)
        return 0;
    length = strlen(value);
    if (length == 38 && value[0] == '{' && value[37] == '}') {
        value++;
        length = 36;
    }
    return length == 36 && !strncasecmp(value, guid, length);
}

static int xml_set_guid(xmlNode *node, const char *source, const char *guid)
{
    char rendered[40];
    int n;

    n = source[0] == '{' ? snprintf(rendered, sizeof(rendered), "{%s}", guid)
                          : snprintf(rendered, sizeof(rendered), "%s", guid);
    if (n < 0 || (size_t)n >= sizeof(rendered))
        return -1;
    return xmlSetProp(node, (const xmlChar *)"guid",
                      (const xmlChar *)rendered)
               ? 0
               : -1;
}

static int xml_u64(const char *text, uint64_t *out)
{
    char *end;
    unsigned long long parsed;

    if (!text || !*text)
        return -1;
    errno = 0;
    parsed = strtoull(text, &end, 10);
    if (errno || *end)
        return -1;
    *out = (uint64_t)parsed;
    return 0;
}

static int xml_location(ctx_t *c, xmlNode *n)
{
    char *gs = (char *)xmlGetProp(n, (const xmlChar *)"guid");
    char *is = (char *)xmlGetProp(n, (const xmlChar *)"id");
    char *os = (char *)xmlGetProp(n, (const xmlChar *)"offset");
    uint64_t off;
    size_t z;

    if (!gs || !is || !os || xml_u64(os, &off))
        goto bad;
    if (off == 0 && strspn(gs, "0{}-") == strlen(gs) && !strcmp(is, "0"))
        goto ok;
    for (z = 0; z < c->nmap; z++) {
        map_t *m = &c->map[z];
        char number[32];

        if (!strcmp(m->table, "gpt") && gs &&
            xml_guid_matches(gs, m->olddisk) && off == m->oldoff) {
            if (xml_set_guid(n, gs, m->newdisk) ||
                snprintf(number, sizeof(number), "%llu",
                         (unsigned long long)m->newoff) < 0)
                goto bad;
            if (!xmlSetProp(n, (const xmlChar *)"offset",
                            (const xmlChar *)number))
                goto bad;
            c->xml_updates++;
            goto ok;
        }
        if (!strcmp(m->table, "mbr") && is) {
            unsigned old;
            unsigned new_id;

            if (sscanf(is, "%u", &old) == 1 &&
                sscanf(m->olddisk, "%x", &new_id) == 1 && old == new_id &&
                off == m->oldoff) {
                if (sscanf(m->newdisk, "%x", &new_id) != 1 ||
                    snprintf(number, sizeof(number), "%u", new_id) < 0)
                    goto bad;
                if (!xmlSetProp(n, (const xmlChar *)"id",
                                (const xmlChar *)number))
                    goto bad;
                if (snprintf(number, sizeof(number), "%llu",
                             (unsigned long long)m->newoff) < 0)
                    goto bad;
                if (!xmlSetProp(n, (const xmlChar *)"offset",
                                (const xmlChar *)number))
                    goto bad;
                c->xml_updates++;
                goto ok;
            }
        }
    }
    goto bad;

ok:
    if (gs)
        xmlFree(gs);
    if (is)
        xmlFree(is);
    if (os)
        xmlFree(os);
    return 0;

bad:
    if (gs)
        xmlFree(gs);
    if (is)
        xmlFree(is);
    if (os)
        xmlFree(os);
    return -1;
}
static int unsupported_xml_location(xmlNode *node)
{
    xmlAttr *attribute;
    char *content = (char *)xmlNodeGetContent(node);
    int invalid = content &&
                  strspn(content, " \t\r\n0{}-") != strlen(content);

    xmlFree(content);
    for (attribute = node->properties; attribute && !invalid;
         attribute = attribute->next) {
        xmlChar *value = xmlNodeListGetString(node->doc, attribute->children,
                                              1);

        invalid = value && strspn((char *)value, " \t\r\n0{}-") !=
                               strlen((char *)value);
        xmlFree(value);
    }
    return invalid;
}

static int xml_walk(ctx_t *c, xmlNode *node)
{
    for (; node; node = node->next) {
        if (node->type != XML_ELEMENT_NODE)
            continue;
        if ((!xmlStrcasecmp(node->name, (const xmlChar *)"PBRImageLocation") ||
             !xmlStrcasecmp(node->name,
                             (const xmlChar *)"PBRCustomImageLocation") ||
             !xmlStrcasecmp(node->name,
                             (const xmlChar *)"DownlevelWinreLocation")) &&
            unsupported_xml_location(node))
            return -1;
        if ((!xmlStrcasecmp(node->name, (const xmlChar *)"WinreLocation") ||
             !xmlStrcasecmp(node->name, (const xmlChar *)"ImageLocation")) &&
            xml_location(c, node))
            return -1;
        if (xml_walk(c, node->children))
            return -1;
    }
    return 0;
}

static int xml_file(ctx_t *c, const char *path)
{
    xmlDocPtr document = xmlReadFile(path, NULL,
                                     XML_PARSE_NONET | XML_PARSE_NOERROR |
                                         XML_PARSE_NOWARNING);
    int result;

    if (!document || document->intSubset || document->extSubset) {
        if (document)
            xmlFreeDoc(document);
        return -1;
    }
    result = xml_walk(c, xmlDocGetRootElement(document));
    if (!result && xmlSaveFormatFileEnc(path, document, "UTF-8", 0) < 0)
        result = -1;
    xmlFreeDoc(document);
    return result;
}

static int edit(ctx_t *c, const char *path, size_t index)
{
    if (index < c->nbcd)
        return bcd_file(c, path);
    if (index == c->nbcd)
        return mounted_file(c, path);
    return xml_file(c, path);
}

static int stage_input_path(char out[PATH_MAX], const ctx_t *c,
                            const char *name)
{
    char suffix[64];
    int length;

    length = snprintf(suffix, sizeof(suffix), "/input.%s.json", name);
    if (length < 0 || (size_t)length >= sizeof(suffix))
        return -1;
    return join_path(out, c->state, suffix);
}

static int persist_inputs(ctx_t *c)
{
    char manifest[PATH_MAX];
    char plan[PATH_MAX];

    if (!c->manifest_json || !c->plan_json ||
        stage_input_path(manifest, c, "manifest") ||
        stage_input_path(plan, c, "plan") ||
        write_string_file(manifest, c->manifest_json) ||
        write_string_file(plan, c->plan_json))
        return -1;
    return 0;
}

static int inputs_match(ctx_t *c)
{
    char manifest[PATH_MAX];
    char plan[PATH_MAX];

    return c->manifest_json && c->plan_json &&
           !stage_input_path(manifest, c, "manifest") &&
           !stage_input_path(plan, c, "plan") &&
           same_string_file(manifest, c->manifest_json) &&
           same_string_file(plan, c->plan_json);
}

static int candidates_match(ctx_t *c);

static int make_stage(ctx_t *c)
{
    char base[PATH_MAX];
    char state_base[PATH_MAX];
    char p[PATH_MAX];
    size_t i;

    if (join_path(base, c->root, "/.rootpxe-offline-identities") ||
        (mkdir(base, 0700) < 0 && errno != EEXIST) || !dir_ok(base) ||
        join_path(state_base, base, "/") ||
        join_path(c->state, state_base, c->planid))
        return -1;
    if (mkdir(c->state, 0700) < 0) {
        if (errno != EEXIST)
            return -1;
        return -2;
    }
    if (persist_inputs(c))
        return -1;
    for (i = 0; i <= c->nbcd; i++) {
        if (!clean_hive(c->files[i]))
            return -1;
    }
    /* Snapshot every original and candidate before editing any candidate.  A
     * failed edit can therefore never leave a later preflight with a mixture
     * that looks complete. */
    for (i = 0; i < c->nfiles; i++) {
        if (staged_path(p, c, i, ".orig") || copyfile(c->files[i], p))
            return -1;
        if (staged_path(p, c, i, ".new") || copyfile(c->files[i], p))
            return -1;
    }
    for (i = 0; i < c->nfiles; i++) {
        if (staged_path(p, c, i, ".new") || edit(c, p, i))
            return -1;
    }
    if (c->bcd_updates == 0 || c->mounted_updates == 0 ||
        !candidates_match(c))
        return -1;
    return 0;
}

/* Rebuild each candidate from its immutable snapshot before accepting a saved
 * stage.  The completion marker alone is not evidence that a candidate was
 * produced by this plan (it may be left by an interrupted or tampered run). */
static int candidates_match(ctx_t *c)
{
    char original[PATH_MAX];
    char candidate[PATH_MAX];
    char expected[PATH_MAX];
    size_t i;

    for (i = 0; i < c->nfiles; i++) {
        if (staged_path(original, c, i, ".orig") ||
            staged_path(candidate, c, i, ".new") ||
            staged_path(expected, c, i, ".expected") ||
            !regular(original) || !regular(candidate))
            return 0;
        if (unlink(expected) < 0 && errno != ENOENT)
            return 0;
        if (copyfile(original, expected) || edit(c, expected, i) ||
            !samefile(candidate, expected)) {
            unlink(expected);
            return 0;
        }
        if (unlink(expected) < 0)
            return 0;
    }
    return 1;
}

static int staged(ctx_t *c)
{
    char p[PATH_MAX];
    char q[PATH_MAX];
    char marker[PATH_MAX];
    size_t i;

    if (!dir_ok(c->state) || !inputs_match(c) ||
        join_path(marker, c->state, "/preflight.ok") ||
        !same_string_file(marker, "complete\n"))
        return 0;
    for (i = 0; i < c->nfiles; i++) {
        if (staged_path(p, c, i, ".orig") ||
            staged_path(q, c, i, ".new") || !regular(p) || !regular(q) ||
            (!samefile(c->files[i], p) && !samefile(c->files[i], q)))
            return 0;
    }
    return candidates_match(c);
}

static int mark_preflight_complete(ctx_t *c)
{
    char marker[PATH_MAX];

    return join_path(marker, c->state, "/preflight.ok") ||
                   write_string_file(marker, "complete\n")
               ? -1
               : 0;
}

static int mark_phase(ctx_t *c, const char *s)
{
    char p[PATH_MAX];
    int fd;

    if (join_path(p, c->state, "/phase"))
        return -1;
    fd = open(p, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0 || write(fd, s, strlen(s)) != (ssize_t)strlen(s) ||
        fsync(fd) < 0) {
        if (fd >= 0)
            close(fd);
        return -1;
    }
    return close(fd);
}
static int reopen_candidate(ctx_t *c, size_t index, const char *path)
{
    hive_h *hive;
    xmlDocPtr document;

    if (index < c->nbcd + 1) {
        hive = hivex_open(path, 0);
        if (!hive)
            return -1;
        hivex_close(hive);
        return 0;
    }
    document = xmlReadFile(path, NULL,
                           XML_PARSE_NONET | XML_PARSE_NOERROR |
                               XML_PARSE_NOWARNING);
    if (!document || document->intSubset || document->extSubset) {
        if (document)
            xmlFreeDoc(document);
        return -1;
    }
    xmlFreeDoc(document);
    return 0;
}
static int run(ctx_t *c, const char *phase, const char *out)
{
    char p[PATH_MAX];
    size_t i;
    int r;
    int done = 0;
    int winre = c->nxml > 0;
    FILE *f;

    if (!strcmp(phase, "preflight")) {
        r = make_stage(c);
        if (r == -2) {
            if (!staged(c))
                die("阶段目录不属于当前原件；拒绝覆盖");
        } else if (r) {
            die("预检或候选副本修复失败");
        }
        if (mark_phase(c, "preflight"))
            die("不能持久记录预检阶段");
        if (r != -2 && mark_preflight_complete(c))
            die("不能持久记录完整预检状态");
    } else if (!strcmp(phase, "apply")) {
        if (!staged(c))
            die("缺少同计划阶段记录或原件已漂移");
        for (i = 0; i < c->nfiles; i++) {
            if (staged_path(p, c, i, ".new"))
                die("阶段候选路径过长");
            if (samefile(c->files[i], p))
                continue;
            if (atomic_install(p, c->files[i]))
                die("安装阶段失败；保留备份和阶段记录");
            if (mark_phase(c, "apply"))
                die("不能持久记录安装阶段");
        }
        done = 1;
    } else if (!strcmp(phase, "verify")) {
        if (!staged(c))
            die("缺少同计划阶段记录");
        for (i = 0; i < c->nfiles; i++) {
            if (staged_path(p, c, i, ".new") ||
                !samefile(c->files[i], p) || reopen_candidate(c, i, c->files[i]))
                die("验证发现文件未安装或无法重新打开");
        }
        if (mark_phase(c, "verify"))
            die("不能持久记录验证阶段");
        done = 1;
    } else {
        die("无效 phase");
    }
    f = fopen(out, "wx");
    if (!f)
        die("不能创建 result");
    fprintf(f,
            "{\"version\":1,\"storage\":false,\"bcd\":%s,"
            "\"mountedDevices\":%s,\"winre\":%s,\"winreApplicable\":%s,"
            "\"phase\":\"%s\",\"message\":\"disk IDs, EFI NVRAM and WIM "
            "are outside this tool\"}\n",
            done ? "true" : "false", done ? "true" : "false",
            done && winre ? "true" : "false", winre ? "true" : "false",
            phase);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    chmod(out, 0600);
    return 0;
}
static int selftest(void)
{
    ctx_t c = {0};
    unsigned char object[16], full[16 + 0x48], outer[0x34 + 0x48];
    unsigned char old[16], nw[16], *r;
    static const char xml[] =
        "<r><WinreBCD id=\"{00112233-4455-6677-8899-aabbccddeeff}\"/>"
        "<WinreLocation guid=\"11111111-2222-3333-4444-555555555555\" "
        "id=\"0\" offset=\"4096\"/><ImageLocation "
        "guid=\"{00000000-0000-0000-0000-000000000000}\" id=\"0\" "
        "offset=\"0\"/></r>";
    int changed = 0;
    xmlDocPtr d;
    xmlNode *n;
    xmlChar *guid;
    xmlChar *offset;

    strcpy(c.map[0].table, "mbr");
    strcpy(c.map[0].olddisk, "f1234567");
    strcpy(c.map[0].newdisk, "0000000a");
    c.map[0].oldoff = 0x100000010ULL;
    c.map[0].newoff = 0x200000020ULL;
    c.nmap = 1;
    memset(object, 0xa5, sizeof(object));
    memset(full, 0, sizeof(full));
    memcpy(full, object, sizeof(object));
    r = full + 16;
    put32(r, 6); put32(r + 8, 0x48); put32(r + 0x24, 1);
    put64(r + 0x10, c.map[0].oldoff); put32(r + 0x28, 0xf1234567U);
    if (fix_record(&c, r, 0x48, 0, &changed) || !changed ||
        memcmp(full, object, sizeof(object)) || le64(r + 0x10) != c.map[0].newoff ||
        (uint32_t)le32(r + 0x28) != 10U)
        return -1;
    c.map[1] = c.map[0];
    c.nmap = 2;
    {
        map_t *ambiguous = NULL;

        if (mbrmap(&c, 0xf1234567U, c.map[0].oldoff, &ambiguous) != -1)
            return -1;
    }
    c.nmap = 1;
    memset(outer, 0, sizeof(outer));
    put32(outer, 0); put32(outer + 8, sizeof(outer));
    memcpy(outer + 0x34, r, 0x48);
    put64(outer + 0x34 + 0x10, c.map[0].oldoff);
    put32(outer + 0x34 + 0x28, 0xf1234567U);
    changed = 0;
    if (fix_record(&c, outer, sizeof(outer), 0, &changed) || !changed ||
        le64(outer + 0x34 + 0x10) != c.map[0].newoff ||
        (uint32_t)le32(outer + 0x34 + 0x28) != 10U)
        return -1;
    put32(r, 7);
    if (fix_record(&c, r, 0x48, 0, &changed) != -1)
        return -1;
    strcpy(c.map[0].table, "gpt");
    strcpy(c.map[0].olddisk, "11111111-2222-3333-4444-555555555555");
    strcpy(c.map[0].newdisk, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    strcpy(c.map[0].oldpart, "12345678-9abc-def0-1122-334455667788");
    strcpy(c.map[0].newpart, "87654321-cba9-0fed-8877-665544332211");
    if (guid_bytes(c.map[0].olddisk, old) || guid_bytes(c.map[0].oldpart, nw) ||
        guid_bytes(c.map[0].newdisk, r) || guid_bytes(c.map[0].newpart, r + 16))
        return -1;
    memset(outer, 0, sizeof(outer));
    put32(outer, 6); put32(outer + 8, 0x48); put32(outer + 0x24, 0);
    memcpy(outer + 0x10, nw, 16); memcpy(outer + 0x28, old, 16);
    changed = 0;
    if (fix_record(&c, outer, 0x48, 0, &changed) || !changed ||
        memcmp(outer + 0x28, r, 16) || memcmp(outer + 0x10, r + 16, 16))
        return -1;
    c.map[1] = c.map[0];
    c.nmap = 2;
    {
        map_t *ambiguous = NULL;

        if (gptmap(&c, old, nw, &ambiguous) != -1)
            return -1;
    }
    c.nmap = 1;
    strcpy(c.map[0].table, "gpt");
    strcpy(c.map[0].olddisk, "11111111-2222-3333-4444-555555555555");
    strcpy(c.map[0].newdisk, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    d = xmlReadMemory(xml, sizeof(xml) - 1, "x", NULL, XML_PARSE_NONET);
    if (!d)
        return -1;
    n = child(xmlDocGetRootElement(d), "WinreLocation");
    c.map[0].oldoff = 4096; c.map[0].newoff = 8192;
    if (xml_location(&c, n)) { xmlFreeDoc(d); return -1; }
    guid = xmlGetProp(n, (const xmlChar *)"guid");
    offset = xmlGetProp(n, (const xmlChar *)"offset");
    if (!guid || !offset || strcmp((char *)guid, c.map[0].newdisk) ||
        strcmp((char *)offset, "8192")) {
        xmlFree(guid); xmlFree(offset); xmlFreeDoc(d); return -1;
    }
    xmlFree(guid); xmlFree(offset);
    if (xml_location(&c, child(xmlDocGetRootElement(d), "ImageLocation"))) {
        xmlFreeDoc(d); return -1;
    }
    xmlFreeDoc(d);
    return 0;
}
int main(int argc, char **argv)
{
    const char *manifest = NULL;
    const char *plan = NULL;
    const char *result = NULL;
    const char *phase = NULL;
    ctx_t context = {0};
    int i;

    if (argc == 2 && !strcmp(argv[1], "selftest"))
        return selftest() ? 1 : 0;
    if (argc >= 2 && !strcmp(argv[1], "efi-repair"))
        return rootpxe_efi_main(argc - 1, argv + 1);
    if (argc < 2 || strcmp(argv[1], "windows-repair"))
        die("用法: windows-repair --manifest FILE --plan FILE --result FILE --phase PHASE");
    for (i = 2; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--manifest"))
            manifest = argv[i + 1];
        else if (!strcmp(argv[i], "--plan"))
            plan = argv[i + 1];
        else if (!strcmp(argv[i], "--result"))
            result = argv[i + 1];
        else if (!strcmp(argv[i], "--phase"))
            phase = argv[i + 1];
        else
            die("未知参数");
    }
    if (!manifest || !plan || !result || !phase || !regular(manifest) ||
        !regular(plan))
        die("参数文件必须为普通文件");
    if (read_manifest(&context, manifest, plan))
        die("manifest 或 plan 不符合 v1 受限契约");
    return run(&context, phase, result);
}
