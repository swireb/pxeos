#ifndef ROOTPXE_STORAGE_FS_H
#define ROOTPXE_STORAGE_FS_H
#include "storage_context.h"
#include <linux/stat.h>
struct storage_fs{struct storage_context *context;int root,result;struct statx root_stat;uint64_t last_count,last_sequence;};
int rx_fs_open(struct storage_fs *,struct storage_context *);
int rx_command(struct storage_fs *,struct json_object *,int,int,int);
int rx_stat_fd(int,struct statx *);
struct json_object *rx_node_json(const struct statx *);
#endif
