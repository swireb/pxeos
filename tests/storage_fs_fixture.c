#include "storage_context.h"
#include "storage_fs.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

/* Real storage_fs code, local temporary directories and child IPC only.
 * No mount, identity change, NAS, block device or production path is used. */
static void key_for(const char *path, char key[65]) {
    unsigned char digest[32]; unsigned length=0;
    assert(EVP_Digest(path,strlen(path),digest,&length,EVP_sha256(),NULL)==1&&length==32);
    for(unsigned i=0;i<32;i++)snprintf(key+i*2,3,"%02x",digest[i]);
}
static void add_proof(struct json_object *proof,int root,const char *path) {
    int fd=*path?openat(root,path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC):dup(root);
    if(fd<0){assert(errno==ENOENT);return;}
    struct statx st;assert(!rx_stat_fd(fd,&st));assert(!close(fd));
    char key[65],seconds[32],nanos[16];key_for(path,key);
    struct json_object *node=rx_node_json(&st);
    snprintf(seconds,sizeof(seconds),"%lld",(long long)st.stx_mtime.tv_sec);
    snprintf(nanos,sizeof(nanos),"%u",st.stx_mtime.tv_nsec);
    json_object_object_add(node,"mtimeSec",json_object_new_string(seconds));
    json_object_object_add(node,"mtimeNsec",json_object_new_string(nanos));
    json_object_object_add(proof,key,node);
}
static struct json_object *proof_for(int root,const char *path) {
    struct json_object *proof=json_object_new_object();add_proof(proof,root,"");
    char copy[4096];assert(strlen(path)<sizeof(copy));strcpy(copy,path);
    for(char *p=copy;*p;p++)if(*p=='/'){*p=0;add_proof(proof,root,copy);*p='/';}
    add_proof(proof,root,path);return proof;
}
static void send_ack(int request,int root,struct json_object *event,int corrupt) {
    struct json_object *ack=json_object_new_object(),*value=NULL;
    const char *fields[]={"sequence","execution","operation","path","to"};
    for(unsigned i=0;i<5;i++)if(json_object_object_get_ex(event,fields[i],&value))json_object_object_add(ack,fields[i],json_object_get(value));
    json_object_object_add(ack,"event",json_object_new_string("ack"));
    json_object_object_add(ack,"phase",json_object_new_string(corrupt?"created":rx_string(event,"event",8)));
    json_object_object_add(ack,"proof",proof_for(root,rx_string(event,"path",4095)));
    assert(!rx_emit(request,ack));json_object_put(ack);
}
static struct json_object *command(struct storage_context *context,const char *path,uint64_t sequence,int fixed,uint64_t size) {
    struct json_object *c=json_object_new_object();char number[32];snprintf(number,sizeof(number),"%llu",(unsigned long long)sequence);
    json_object_object_add(c,"execution",json_object_get(context->owner));
    json_object_object_add(c,"sequence",json_object_new_string(number));
    json_object_object_add(c,"operation",json_object_new_string("write"));
    json_object_object_add(c,"path",json_object_new_string(path));
    json_object_object_add(c,"lengthMode",json_object_new_string(fixed?"fixed":"stream"));snprintf(number,sizeof(number),"%llu",(unsigned long long)size);if(fixed)json_object_object_add(c,"expectedSize",json_object_new_string(number));
    return c;
}
static void write_bytes(int fd,uint64_t size) {
    unsigned char buffer[16384];memset(buffer,'x',sizeof(buffer));
    while(size){size_t n=size<sizeof(buffer)?(size_t)size:sizeof(buffer);if(rx_write_all(fd,buffer,n))_exit(12);size-=n;}
}

/* queued_data reaches the pipe before the created ACK, so a zero-size file at
 * that event proves that bulk bytes cannot cross the receipt barrier. */
static void one_case(uint64_t expected,uint64_t actual,int fixed,int reject_result) {
    char temporary[]="/tmp/rootpxe-fs-fixture.XXXXXX";assert(mkdtemp(temporary));
    int root=open(temporary,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(root>=0);
    assert(!mkdirat(root,"dev",0700));assert(!mkdirat(root,"dev/27",0700));assert(!mkdirat(root,"dev/27/2",0700));assert(!mkdirat(root,"dev/27/2/payload",0700));
    int request[2],result[2],data[2];assert(!pipe(request)&&!pipe(result)&&!pipe(data));
    struct storage_context context={0};strcpy(context.protocol,"nfs");strcpy(context.stage,"dev/27/2");strcpy(context.lock,".locks/key");strcpy(context.image_path,"image");context.data_write=1;context.parent=getpid();context.owner=json_tokener_parse("{\"taskType\":\"capture\",\"nonce\":\"fixture\"}");
    pid_t child=fork();assert(child>=0);
    if(!child){close(request[1]);close(result[0]);close(data[1]);struct storage_fs fs={.root=root,.context=&context};assert(!rx_stat_fd(root,&fs.root_stat));struct json_object *c=command(&context,"dev/27/2/payload/file",1,fixed,expected);int rc=rx_command(&fs,c,request[0],data[0],result[1]);json_object_put(c);if(reject_result){assert(rc&&fs.last_sequence==0);c=command(&context,"dev/27/2/payload",4,0,0);json_object_object_add(c,"operation",json_object_new_string("seal"));assert(rx_command(&fs,c,request[0],data[0],result[1]));json_object_put(c);}close(result[1]);_exit(rc?7:0);}
    close(request[0]);close(result[1]);close(data[0]);
    pid_t producer=fork();assert(producer>=0);if(!producer){close(request[1]);close(result[0]);write_bytes(data[1],actual);close(data[1]);_exit(0);}close(data[1]);
    int created=0,results=0,refused=0;struct json_object *event;
    while((event=rx_read_json(result[0],65536,1))){const char *phase=rx_string(event,"event",8);if(!strcmp(phase,"progress")){json_object_put(event);continue;}
        const char *path=rx_string(event,"path",4095);assert(path);
        if(!strcmp(phase,"created")){int fd=openat(root,path,O_RDONLY|O_NOFOLLOW);struct stat st;assert(fd>=0&&!fstat(fd,&st)&&st.st_size==0);close(fd);created++;}
        if(!strcmp(phase,"result")){results++;if(reject_result){close(request[1]);request[1]=-1;refused=1;json_object_put(event);continue;}}
        assert(request[1]>=0);send_ack(request[1],root,event,0);json_object_put(event);
    }
    if(request[1]>=0)close(request[1]);close(result[0]);int status=0;assert(waitpid(child,&status,0)==child&&WIFEXITED(status));
    int success=fixed?expected==actual:1;if(reject_result)success=0;assert((WEXITSTATUS(status)==0)==success);assert(created>=1);if(success)assert(results==1);if(reject_result)assert(refused&&results==1);
    int producer_status;assert(waitpid(producer,&producer_status,0)==producer);assert(WIFEXITED(producer_status)&&WEXITSTATUS(producer_status)==0);
    assert(!unlinkat(root,"dev/27/2/payload/file",0));
    assert(!unlinkat(root,"dev/27/2/payload",AT_REMOVEDIR));assert(!unlinkat(root,"dev/27/2",AT_REMOVEDIR));assert(!unlinkat(root,"dev/27",AT_REMOVEDIR));assert(!unlinkat(root,"dev",AT_REMOVEDIR));close(root);assert(!rmdir(temporary));json_object_put(context.owner);
}

static void two_files_one_fifo(void) {
    char temporary[]="/tmp/rootpxe-fifo-fixture.XXXXXX";assert(mkdtemp(temporary));int root=open(temporary,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);assert(root>=0);assert(!mkdirat(root,"dev",0700));assert(!mkdirat(root,"dev/27",0700));assert(!mkdirat(root,"dev/27/2",0700));assert(!mkfifoat(root,"data",0600));
    int request[2],result[2];assert(!pipe(request)&&!pipe(result));struct storage_context context={0};strcpy(context.protocol,"nfs");strcpy(context.stage,"dev/27/2");strcpy(context.lock,".locks/key");strcpy(context.image_path,"image");context.data_write=1;context.parent=getpid();context.owner=json_tokener_parse("{\"taskType\":\"capture\"}");
    pid_t child=fork();assert(child>=0);if(!child){close(request[1]);close(result[0]);int data=openat(root,"data",O_RDONLY|O_NOFOLLOW);assert(data>=0);struct storage_fs fs={.root=root,.context=&context};assert(!rx_stat_fd(root,&fs.root_stat));for(int i=0;i<2;i++){struct json_object *c=command(&context,i?"dev/27/2/b":"dev/27/2/a",i?4:1,1,3);if(rx_command(&fs,c,request[0],data,result[1]))_exit(7);json_object_put(c);}close(data);close(result[1]);_exit(0);}
    close(request[0]);close(result[1]);int writer=openat(root,"data",O_WRONLY|O_NOFOLLOW);assert(writer>=0);write_bytes(writer,3);close(writer);int results=0;struct json_object *event;
    while((event=rx_read_json(result[0],65536,1))){int finished=!strcmp(rx_string(event,"event",8),"result");send_ack(request[1],root,event,0);json_object_put(event);if(finished&&++results==1){writer=openat(root,"data",O_WRONLY|O_NOFOLLOW);assert(writer>=0);write_bytes(writer,3);close(writer);}}
    assert(results==2);close(request[1]);close(result[0]);int status;assert(waitpid(child,&status,0)==child&&WIFEXITED(status)&&!WEXITSTATUS(status));assert(!unlinkat(root,"dev/27/2/a",0)&&!unlinkat(root,"dev/27/2/b",0));assert(!unlinkat(root,"dev/27/2",AT_REMOVEDIR)&&!unlinkat(root,"dev/27",AT_REMOVEDIR)&&!unlinkat(root,"dev",AT_REMOVEDIR)&&!unlinkat(root,"data",0));close(root);assert(!rmdir(temporary));json_object_put(context.owner);
}
int main(void) {one_case(4,3,1,0);one_case(3,4,1,0);one_case(3,3,1,0);one_case(3,3,1,1);one_case(0,3,0,1);one_case(0,209715207,0,0);two_files_one_fifo();return 0;}
