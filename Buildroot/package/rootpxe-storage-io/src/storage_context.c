#include "storage_context.h"
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/capability.h>
#include <linux/magic.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fsuid.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/vfs.h>
#include <unistd.h>

const char *rx_string(struct json_object *o,const char *key,size_t max){struct json_object *v=NULL;if(!json_object_object_get_ex(o,key,&v)||!json_object_is_type(v,json_type_string))return NULL;const char *s=json_object_get_string(v);size_t n=json_object_get_string_len(v);return n<=max&&strlen(s)==n?s:NULL;}
int rx_u64(struct json_object *o,const char *key,uint64_t *value){struct json_object *v=NULL;if(!json_object_object_get_ex(o,key,&v)||!json_object_is_type(v,json_type_int))return -1;const char *s=json_object_get_string(v);if(!s||s[0]=='-')return -1;errno=0;char *end;unsigned long long n=strtoull(s,&end,10);if(errno||*end)return -1;*value=n;return 0;}
int rx_sequence(struct json_object *o,uint64_t *value){const char *s=rx_string(o,"sequence",20);if(!s||!*s||*s=='0')return -1;for(const char *p=s;*p;p++)if(*p<'0'||*p>'9')return -1;errno=0;char *end;unsigned long long n=strtoull(s,&end,10);if(errno||*end)return -1;*value=n;return 0;}
int rx_hex(const char *s,size_t n){if(!s||strlen(s)!=n)return 0;int nonzero=0;for(size_t i=0;i<n;i++){if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return 0;if(s[i]!='0')nonzero=1;}return nonzero;}
int rx_relative(const char *path,int empty){if(!path||strlen(path)>4095)return 0;if(!*path)return empty;if(*path=='/'||path[strlen(path)-1]=='/')return 0;const char *p=path;size_t atoms=0;while(*p){const char *end=strchr(p,'/');size_t n=end?(size_t)(end-p):strlen(p);if(!n||n>255||(n==1&&p[0]=='.')||(n==2&&p[0]=='.'&&p[1]=='.')||++atoms>32)return 0;for(size_t i=0;i<n;i++)if((unsigned char)p[i]<32||p[i]==127||p[i]=='\\')return 0;if(!end)break;p=end+1;}return 1;}
int rx_write_all(int fd,const void *data,size_t length){const unsigned char *p=data;while(length){ssize_t n=write(fd,p,length);if(n<0&&errno==EINTR)continue;if(n<=0)return -1;p+=n;length-=(size_t)n;}return 0;}
struct json_object *rx_read_json(int fd,size_t max,int line){char *b=malloc(max+1);if(!b)return NULL;size_t n=0;int complete=0;while(n<max){char c;ssize_t r=read(fd,&c,1);if(r<0&&errno==EINTR)continue;if(r<0){free(b);return NULL;}if(!r){complete=!line;break;}if(!c){free(b);return NULL;}if(line&&c=='\n'){complete=1;break;}b[n++]=c;}if(!complete||!n){free(b);return NULL;}b[n]=0;struct json_tokener *t=json_tokener_new_ex(32);if(!t){free(b);return NULL;}json_tokener_set_flags(t,JSON_TOKENER_STRICT|JSON_TOKENER_VALIDATE_UTF8);struct json_object *o=json_tokener_parse_ex(t,b,(int)n);if(json_tokener_get_error(t)!=json_tokener_success||json_tokener_get_parse_end(t)!=n||!json_object_is_type(o,json_type_object)){if(o)json_object_put(o);o=NULL;}json_tokener_free(t);free(b);return o;}
int rx_emit(int fd,struct json_object *o){const char *s=json_object_to_json_string_ext(o,JSON_C_TO_STRING_PLAIN);size_t n=strlen(s);return n<RX_RESULT_MAX&&rx_write_all(fd,s,n)==0&&rx_write_all(fd,"\n",1)==0?0:-1;}
static int version_ok(const char *p,const char *v){if(!strcmp(p,"nfs"))return !strcmp(v,"auto")||!strcmp(v,"3")||!strcmp(v,"4.0")||!strcmp(v,"4.1")||!strcmp(v,"4.2");return !strcmp(v,"auto")||!strcmp(v,"2.1")||!strcmp(v,"3.0")||!strcmp(v,"3.0.2")||!strcmp(v,"3.1.1");}
int rx_load_context(int fd,struct storage_context *c){memset(c,0,sizeof(*c));c->parent=getppid();struct stat s;struct statfs fs;if(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_uid!=0||(s.st_mode&077)||fstatfs(fd,&fs)||fs.f_type==NFS_SUPER_MAGIC||fs.f_type==CIFS_SUPER_MAGIC)return -1;c->json=rx_read_json(fd,RX_COMMAND_MAX,0);if(!c->json)return -1;uint64_t v;if(rx_u64(c->json,"version",&v)||v!=1)return -1;const char *p=rx_string(c->json,"protocol",3),*server=rx_string(c->json,"server",255),*root=rx_string(c->json,"exportPath",4095),*image=rx_string(c->json,"imagePath",4095),*dir=rx_string(c->json,"direction",5);if(!p||(!strcmp(p,"nfs")?0:strcmp(p,"smb"))||!server||!*server||!root||!*root||!image||!rx_relative(image,0)||!dir||(strcmp(dir,"read")&&strcmp(dir,"write")))return -1;for(const char *q=server;*q;q++)if((unsigned char)*q<=32||*q==127||strchr("/,\\;|&$`",*q))return -1;strcpy(c->protocol,p);strcpy(c->server,server);c->port=!strcmp(p,"nfs")?2049:445;char *port_start=NULL;if(c->server[0]=='['){char *end=strchr(c->server,']');if(!end)return -1;if(end[1]){if(end[1]!=':')return -1;port_start=end+2;end[1]=0;}}else{char *colon=strchr(c->server,':');if(colon&&colon==strrchr(c->server,':')){*colon=0;port_start=colon+1;}}if(port_start){if(!*port_start)return -1;for(char *q=port_start;*q;q++)if(*q<'0'||*q>'9')return -1;errno=0;char *end;unsigned long port=strtoul(port_start,&end,10);if(errno||*end||!port||port>65535)return -1;c->port=(uint16_t)port;}strcpy(c->export_path,root);strcpy(c->image_path,image);c->data_write=!strcmp(dir,"write");const char *sequence=rx_string(c->json,"sequence",20);if(!sequence||!*sequence)return -1;if(strcmp(sequence,"0")){if(rx_sequence(c->json,&c->sequence))return -1;}
    if(!json_object_object_get_ex(c->json,"execution",&c->owner)||!json_object_is_type(c->owner,json_type_object))return -1;const char *domain=rx_string(c->owner,"domainId",32),*kind=rx_string(c->owner,"taskType",7),*task=rx_string(c->owner,"taskId",64),*nonce=rx_string(c->owner,"nonce",32),*target=rx_string(c->owner,"targetKey",64),*revision=rx_string(c->owner,"configRevision",64);uint64_t attempt;if(!rx_hex(domain,32)||!kind||(strcmp(kind,"capture")&&strcmp(kind,"deploy"))||!task||!*task||!rx_relative(task,0)||strchr(task,'/')||!rx_hex(nonce,32)||!rx_hex(target,64)||!rx_hex(revision,64)||rx_u64(c->owner,"executionAttempt",&attempt)||!attempt)return -1;snprintf(c->stage,sizeof(c->stage),"dev/%s/%llu",task,(unsigned long long)attempt);snprintf(c->lock,sizeof(c->lock),".locks/%s",target);
    const char *ver=rx_string(c->json,!strcmp(p,"nfs")?"nfsVersion":"smbVersion",15);if(!ver||!version_ok(p,ver))return -1;strcpy(c->version,ver);if(!strcmp(p,"nfs")){uint64_t uid,gid;if(root[0]!='/'||(!root[1]?0:!rx_relative(root+1,0))||rx_u64(c->json,"nfsUid",&uid)||rx_u64(c->json,"nfsGid",&gid)||uid>4294967294ULL||gid>4294967294ULL)return -1;c->uid=(uint32_t)uid;c->gid=(uint32_t)gid;}else if(!rx_relative(root,0))return -1;return 0;}
static int caps_only(int admin){struct __user_cap_header_struct h={_LINUX_CAPABILITY_VERSION_3,0};struct __user_cap_data_struct d[2]={{0}};if(admin){d[CAP_SYS_ADMIN/32].effective=1U<<(CAP_SYS_ADMIN%32);d[CAP_SYS_ADMIN/32].permitted=d[CAP_SYS_ADMIN/32].effective;}return (int)syscall(SYS_capset,&h,d);}
int rx_clear_capabilities(void){return caps_only(0);}
/* getppid is unaffected by signal permission after dropping to another UID.
 * Reparenting after death breaks this binding; PDEATHSIG covers the race after
 * the identity transition. A root parent's kill(0) EPERM is not death. */
int rx_parent_alive(const struct storage_context *c){return c->parent>1&&getppid()==c->parent;}
int rx_identity(struct storage_context *c,int mount_only){
    if(prctl(PR_CAP_AMBIENT,PR_CAP_AMBIENT_CLEAR_ALL,0,0,0))return -1;
    for(int cap=0;cap<64;cap++){int present=prctl(PR_CAPBSET_READ,cap,0,0,0);if(present<0){if(errno==EINVAL)break;return -1;}if(present&&(!mount_only||cap!=CAP_SYS_ADMIN)&&prctl(PR_CAPBSET_DROP,cap,0,0,0))return -1;}
    if(!strcmp(c->protocol,"nfs")){
        if(prctl(PR_SET_KEEPCAPS,mount_only?1:0,0,0,0))return -1;gid_t group=(gid_t)c->gid;
        if(setgroups(1,&group)||setresgid(group,group,group)||setresuid((uid_t)c->uid,(uid_t)c->uid,(uid_t)c->uid))return -1;
        uid_t r,e,s;gid_t gr,ge,gs;if(getresuid(&r,&e,&s)||getresgid(&gr,&ge,&gs)||r!=c->uid||e!=c->uid||s!=c->uid||gr!=c->gid||ge!=c->gid||gs!=c->gid||(uint32_t)setfsuid((uid_t)-1)!=c->uid||(uint32_t)setfsgid((gid_t)-1)!=c->gid)return -1;
        gid_t observed[2];if(getgroups(2,observed)!=1||observed[0]!=group)return -1;
    }else if(mount_only)return -1;
    if(caps_only(mount_only)||prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)||prctl(PR_SET_PDEATHSIG,SIGTERM)||!rx_parent_alive(c))return -1;
    return 0;
}
int rx_fd_contract(int request,int data,int result){for(int fd=3;fd<=6;fd++){if(fd!=request&&fd!=data&&fd!=result&&fd!=3)return -1;struct stat s;struct statfs fs;if(fstat(fd,&s)||fstatfs(fd,&fs)||fs.f_type==NFS_SUPER_MAGIC||fs.f_type==CIFS_SUPER_MAGIC||fs.f_type==SMB2_SUPER_MAGIC||fs.f_type==SMB_SUPER_MAGIC||S_ISBLK(s.st_mode)||S_ISCHR(s.st_mode))return -1;if(fd!=3&&!S_ISFIFO(s.st_mode))return -1;}return 0;}
