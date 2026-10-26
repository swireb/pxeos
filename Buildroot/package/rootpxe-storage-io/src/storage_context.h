#ifndef ROOTPXE_STORAGE_CONTEXT_H
#define ROOTPXE_STORAGE_CONTEXT_H
#include <json-c/json.h>
#include <stdint.h>
#include <sys/types.h>
#define RX_COMMAND_MAX 16384
#define RX_RESULT_MAX 65536
#define RX_DATA_MAX 131072
struct storage_context {
    struct json_object *json, *owner;
    char protocol[4], server[256], export_path[4096], image_path[4096], version[16];
    char stage[256], lock[128], numeric_address[64];
    uint32_t uid, gid;
    uint16_t port;
    uint64_t sequence;
    int data_write;
    pid_t parent;
};
const char *rx_string(struct json_object *, const char *, size_t);
int rx_u64(struct json_object *, const char *, uint64_t *);
int rx_sequence(struct json_object *,uint64_t *);
int rx_hex(const char *, size_t);
int rx_relative(const char *, int);
int rx_write_all(int, const void *, size_t);
struct json_object *rx_read_json(int, size_t, int);
int rx_emit(int, struct json_object *);
int rx_load_context(int, struct storage_context *);
int rx_identity(struct storage_context *, int);
int rx_parent_alive(const struct storage_context *);
int rx_fd_contract(int, int, int);
int rx_clear_capabilities(void);
#endif
