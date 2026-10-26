#include "storage_context.h"
#include "storage_mount.h"
#include <assert.h>
#include <errno.h>
#include <grp.h>
#include <linux/capability.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/mount.h>
#include <unistd.h>

static uid_t uid;static gid_t gid;static int group_count,group_called,uid_called,gid_called,cap_called,parent_signal,fail_group;
static int mount_called;
int __wrap_mount(const char *source,const char *target,const char *type,unsigned long flags,const void *data){assert(uid==1000&&gid==1001&&parent_signal&&cap_called);assert(!strcmp(source,"192.0.2.1:/NAS images")&&!strcmp(target,"/storage")&&!strcmp(type,"nfs4"));assert(strstr(data,"addr=192.0.2.1")&&strstr(data,"sec=sys")&&strstr(data,"vers=4.1"));assert(!(flags&MS_RDONLY));mount_called++;return 0;}
int __wrap_prctl(int option,...){va_list args;va_start(args,option);unsigned long value=va_arg(args,unsigned long);va_end(args);if(option==PR_CAPBSET_READ){if(value>CAP_LAST_CAP){errno=EINVAL;return -1;}return 1;}if(option==PR_SET_PDEATHSIG){assert(uid_called&&gid_called&&cap_called);parent_signal++;}return 0;}
int __wrap_setgroups(size_t n,const gid_t *groups){group_called++;if(fail_group)return -1;assert(n==1);group_count=1;gid=groups[0];return 0;}
int __wrap_setresgid(gid_t a,gid_t b,gid_t c){assert(group_called&&a==gid&&b==a&&c==a);gid_called++;return 0;}
int __wrap_setresuid(uid_t a,uid_t b,uid_t c){assert(gid_called&&b==a&&c==a);uid=a;uid_called++;return 0;}
int __wrap_getresuid(uid_t *a,uid_t *b,uid_t *c){*a=*b=*c=uid;return 0;}
int __wrap_getresgid(gid_t *a,gid_t *b,gid_t *c){*a=*b=*c=gid;return 0;}
int __wrap_setfsuid(uid_t value){assert(value==(uid_t)-1);return (int)uid;}
int __wrap_setfsgid(gid_t value){assert(value==(gid_t)-1);return (int)gid;}
int __wrap_getgroups(int size,gid_t *groups){assert(size>=1);groups[0]=gid;return group_count;}
pid_t __wrap_getppid(void){return 42;}
int __wrap_kill(pid_t pid,int signal){assert(pid==42&&signal==0);errno=EPERM;return -1;}
long __wrap_syscall(long number,...){assert(number==SYS_capset);va_list args;va_start(args,number);struct __user_cap_header_struct *header=va_arg(args,void*);struct __user_cap_data_struct *data=va_arg(args,void*);va_end(args);assert(header->version==_LINUX_CAPABILITY_VERSION_3);assert(uid_called&&gid_called);assert(!data[0].inheritable&&!data[1].inheritable);uint32_t allowed=1U<<CAP_SYS_ADMIN;assert(!(data[0].effective&~allowed)&&!(data[0].permitted&~allowed)&&!data[1].effective&&!data[1].permitted);cap_called++;return 0;}
static void identity(uint32_t user,uint32_t group,int mount){struct storage_context c={0};strcpy(c.protocol,"nfs");c.uid=user;c.gid=group;c.parent=42;group_called=uid_called=gid_called=cap_called=parent_signal=0;assert(!rx_identity(&c,mount));assert(uid==user&&gid==group&&group_count==1&&parent_signal==1);}
int main(void){identity(1000,1001,0);identity(0,0,0);identity(1000,1001,1);identity(0,1001,1);struct storage_context c={.uid=1000,.gid=1001,.parent=42};strcpy(c.protocol,"nfs");fail_group=1;uid_called=gid_called=cap_called=0;assert(rx_identity(&c,1)<0&&!uid_called&&!gid_called&&!cap_called);fail_group=0;
    strcpy(c.server,"192.0.2.1");strcpy(c.export_path,"/NAS images");strcpy(c.version,"4.1");c.port=2049;c.data_write=1;int results[2];assert(!pipe(results));assert(!rx_mount_nfs(&c,results[1])&&mount_called==1);close(results[1]);char mounted[1024];ssize_t mounted_size=read(results[0],mounted,sizeof(mounted)-1);assert(mounted_size>0);mounted[mounted_size]=0;assert(strstr(mounted,"\"mounted\":true"));close(results[0]);
    struct json_object *numbers=json_tokener_parse("{\"good\":4294967294,\"negative\":-1,\"fraction\":1.5,\"text\":\"0\",\"bool\":false}");uint64_t n;assert(!rx_u64(numbers,"good",&n)&&n==4294967294ULL);assert(rx_u64(numbers,"negative",&n)&&rx_u64(numbers,"fraction",&n)&&rx_u64(numbers,"text",&n)&&rx_u64(numbers,"bool",&n));json_object_put(numbers);assert(rx_relative("build..old/with space",0)&&!rx_relative("a/../b",0)&&!rx_relative("a//b",0));
    char actual[16];struct storage_context smb={0};strcpy(smb.protocol,"smb");strcpy(smb.server,"192.0.2.1");strcpy(smb.export_path,"images/sub");strcpy(smb.version,"auto");assert(!rx_parse_mountinfo("40 1 0:1 /sub /storage rw - cifs //192.0.2.1/images rw,vers=3.02,serverino\n",&smb,actual)&&!strcmp(actual,"3.0.2"));assert(rx_parse_mountinfo("40 1 0:1 /sub /storage rw - cifs //192.0.2.1/images rw,vers=3,serverino\n",&smb,actual));assert(rx_parse_mountinfo("40 1 0:1 /wrong /storage rw - cifs //192.0.2.1/images rw,vers=2.1,serverino\n",&smb,actual));
    const char *normal="\n\t1) Address: 192.0.2.1 Uses: 1 Capability: 0 Session Status: 1 \n\tSecurity type: RawNTLMSSP SessionId: 0xfffffffffffffff1\n\tShares:\n\t1) \\\\192.0.2.1\\images Mounts: 1 \n--\n";char b[2048];strcpy(b,normal);assert(!rx_parse_cifs_session(b,strlen(b),"192.0.2.1","\\\\192.0.2.1\\images",UINT64_C(0xfffffffffffffff1)));strcpy(b,normal);char *status=strstr(b,"Session Status: 1 ");memcpy(status,"Guest            ",17);assert(rx_parse_cifs_session(b,strlen(b),"192.0.2.1","\\\\192.0.2.1\\images",UINT64_C(0xfffffffffffffff1)));return 0;}
