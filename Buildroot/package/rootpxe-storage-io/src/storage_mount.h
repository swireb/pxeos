#ifndef ROOTPXE_STORAGE_MOUNT_H
#define ROOTPXE_STORAGE_MOUNT_H
#include "storage_context.h"
int rx_mount_nfs(struct storage_context *,int);
int rx_resolve_server(struct storage_context *,struct json_object **);
int rx_mount_info(struct storage_context *,int,struct json_object **);
int rx_parse_mountinfo(const char *,struct storage_context *,char [16]);
int rx_parse_cifs_session(char *,size_t,const char *,const char *,uint64_t);
#endif
