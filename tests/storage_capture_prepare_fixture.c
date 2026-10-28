#include "storage_context.h"
#include "storage_fs.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Run the real command/receipt implementation on a caller-owned local tmp
 * directory. stdin carries commands and ACKs, stdout carries helper events,
 * and FD 3 carries owner bytes. No mount or identity transition is performed. */
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    struct storage_context context = {0};
    context.parent = getppid();
    context.data_write = 1;
    strcpy(context.protocol, "nfs");
    strcpy(context.stage, "dev/41/2");
    strcpy(context.image_path, "task.img");
    context.owner = json_tokener_parse(argv[2]);
    const char *target = context.owner ? rx_string(context.owner, "targetKey", 64) : NULL;
    if (!target) return 3;
    snprintf(context.lock, sizeof(context.lock), ".locks/%s", target);
    struct storage_fs fs = {.context = &context};
    fs.root = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fs.root < 0 || rx_stat_fd(fs.root, &fs.root_stat)) return 4;
    struct json_object *command;
    while ((command = rx_read_json(STDIN_FILENO, RX_COMMAND_MAX, 1))) {
        int rc = rx_command(&fs, command, STDIN_FILENO, 3, STDOUT_FILENO);
        json_object_put(command);
        if (rc) return 7;
        struct json_object *done = json_object_new_object();
        json_object_object_add(done, "event", json_object_new_string("done"));
        rc = rx_emit(STDOUT_FILENO, done);
        json_object_put(done);
        if (rc) return 8;
    }
    close(fs.root);
    json_object_put(context.owner);
    return 0;
}
