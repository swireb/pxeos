#include "storage_context.h"
#include "storage_fs.h"
#include "storage_mount.h"
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc,char **argv){if(argc==2&&!strcmp(argv[1],"--capabilities")){const char *caps="{\"version\":1,\"helper\":true,\"numericIdentity\":true,\"durablePublish\":true}\n";return rx_write_all(1,caps,strlen(caps))?1:0;}int mount_only=0,context=-1,request=-1,data=-1,result=-1;for(int i=1;i<argc;i++){if(!strcmp(argv[i],"--mount-nfs")||!strcmp(argv[i],"--resolve")){if(mount_only)return 2;mount_only=!strcmp(argv[i],"--resolve")?2:1;continue;}if(i+1>=argc)return 2;if(strlen(argv[i+1])!=1||argv[i+1][0]<'3'||argv[i+1][0]>'6')return 2;int fd=argv[i+1][0]-'0';if(!strcmp(argv[i],"--context-fd")&&context<0)context=fd;else if(!strcmp(argv[i],"--request-fd")&&request<0)request=fd;else if(!strcmp(argv[i],"--data-fd")&&data<0)data=fd;else if(!strcmp(argv[i],"--result-fd")&&result<0)result=fd;else return 2;i++;}if(context!=3||result!=6||(!mount_only&&(request!=4||data!=5))||(mount_only&&(request!=-1||data!=-1)))return 2;signal(SIGPIPE,SIG_IGN);struct storage_context c;if(rx_load_context(context,&c)||(!mount_only&&rx_fd_contract(request,data,result)))return 3;struct stat result_stat;if(fstat(result,&result_stat)||!S_ISFIFO(result_stat.st_mode))return 3;close(context);if(mount_only){close(4);close(5);}/* No inherited NAS/block descriptors or shell execution surface. */if(chdir("/")||syscall(SYS_close_range,7,~0U,0))return 3;for(int fd=0;fd<3;fd++){close(fd);int null=open("/dev/null",O_RDWR|O_CLOEXEC);if(null!=fd)return 3;}
    if(mount_only==2){struct json_object *resolved=NULL;int rc=rx_resolve_server(&c,&resolved);if(!rc){rc=rx_emit(result,resolved);json_object_put(resolved);}json_object_put(c.json);return rc?4:0;}if(mount_only){int rc=rx_mount_nfs(&c,result);int clear=rx_clear_capabilities();if(prctl(PR_SET_KEEPCAPS,0,0,0,0))clear=-1;json_object_put(c.json);return rc||clear?4:0;}
    /* Validate pipes before dropping identity; this does not open the NAS. */
    for(int fd=4;fd<=6;fd++){struct stat s;if(fstat(fd,&s)||!S_ISFIFO(s.st_mode))return 3;}
    if(rx_identity(&c,0))return 4;struct storage_fs fs={0};fs.last_sequence=c.sequence;if(rx_fs_open(&fs,&c))return 5;struct json_object *info=NULL;if(rx_mount_info(&c,fs.root,&info)){close(fs.root);return 5;}struct json_object *ready=json_object_new_object();json_object_object_add(ready,"event",json_object_new_string("connection-info"));json_object_object_add(ready,"connection",info);json_object_object_add(ready,"node",rx_node_json(&fs.root_stat));if(rx_emit(result,ready)){json_object_put(ready);close(fs.root);return 6;}json_object_put(ready);int rc=0;while(rx_parent_alive(&c)){struct json_object *command=rx_read_json(request,RX_COMMAND_MAX,1);if(!command)break;if(rx_command(&fs,command,request,data,result)){json_object_put(command);rc=7;break;}json_object_put(command);struct json_object *complete=json_object_new_object();json_object_object_add(complete,"event",json_object_new_string("done"));char sequence[21];snprintf(sequence,sizeof(sequence),"%llu",(unsigned long long)fs.last_sequence);json_object_object_add(complete,"sequence",json_object_new_string(sequence));if(rx_emit(result,complete)){json_object_put(complete);rc=7;break;}json_object_put(complete);}if(close(fs.root))rc=7;json_object_put(c.json);return rc;}
