#include "storage_context.h"
#include "storage_fs.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <openssl/evp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Real storage_fs code, local temporary directories and child IPC only.
 * No mount, identity change, NAS, block device or production path is used. */
static int change_fd = -1, change_at_stat, source_stats;
static ino_t change_ino;
static off_t change_size;
#ifdef ROOTPXE_TEST_STATX_RACE
int __real_statx(int, const char *, int, unsigned, struct statx *);
int __wrap_statx(int fd, const char *path, int flags, unsigned mask, struct statx *st) {
    int rc = __real_statx(fd, path, flags, mask, st);
    if (!rc && change_fd >= 0 && S_ISREG(st->stx_mode) && st->stx_ino == change_ino &&
        ++source_stats == change_at_stat) {
        /* Return the observed facts, then change only our private fixture file.
         * This places the change between proof validation and stream startup. */
        assert(!ftruncate(change_fd, change_size));
        if ((uint64_t)change_size == st->stx_size) {
            const struct timespec times[2] = {
                {.tv_nsec=UTIME_OMIT},
                {.tv_sec=st->stx_mtime.tv_sec+1, .tv_nsec=st->stx_mtime.tv_nsec},
            };
            assert(!futimens(change_fd, times));
        }
    }
    return rc;
}
#endif

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

static int64_t elapsed_clock_ms(void) {
    struct timespec stamp;
    assert(!clock_gettime(CLOCK_MONOTONIC, &stamp));
    return (int64_t)stamp.tv_sec * 1000 + stamp.tv_nsec / 1000000;
}

/* queued_data reaches the pipe before the created ACK, so a zero-size file at
 * that event proves that bulk bytes cannot cross the receipt barrier. */
static void one_case(uint64_t expected,uint64_t actual,int fixed,int reject_result) {
    int64_t progress_started=elapsed_clock_ms();
    char temporary[]="rootpxe-fs-fixture.XXXXXX";assert(mkdtemp(temporary));puts(temporary);
    int root=open(temporary,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);assert(root>=0);
    assert(!mkdirat(root,"dev",0700));assert(!mkdirat(root,"dev/27",0700));assert(!mkdirat(root,"dev/27/2",0700));assert(!mkdirat(root,"dev/27/2/payload",0700));
    int request[2],result[2],data[2];assert(!pipe(request)&&!pipe(result)&&!pipe(data));
    struct storage_context context={0};strcpy(context.protocol,"nfs");strcpy(context.stage,"dev/27/2");strcpy(context.lock,".locks/key");strcpy(context.image_path,"image");context.data_write=1;context.parent=getpid();context.owner=json_tokener_parse("{\"taskType\":\"capture\",\"nonce\":\"fixture\"}");
    pid_t child=fork();assert(child>=0);
    if(!child){close(request[1]);close(result[0]);close(data[1]);struct storage_fs fs={.root=root,.context=&context};assert(!rx_stat_fd(root,&fs.root_stat));struct json_object *c=command(&context,"dev/27/2/payload/file",1,fixed,expected);int rc=rx_command(&fs,c,request[0],data[0],result[1]);json_object_put(c);if(reject_result){assert(rc&&fs.last_sequence==0);c=command(&context,"dev/27/2/payload",4,0,0);json_object_object_add(c,"operation",json_object_new_string("seal"));assert(rx_command(&fs,c,request[0],data[0],result[1]));json_object_put(c);}close(result[1]);_exit(rc?7:0);}
    close(request[0]);close(result[1]);close(data[0]);
    pid_t producer=fork();assert(producer>=0);if(!producer){close(request[1]);close(result[0]);write_bytes(data[1],actual);close(data[1]);_exit(0);}close(data[1]);
    int created=0,results=0,refused=0,progress_events=0;struct json_object *event;
    while((event=rx_read_json(result[0],65536,1))){const char *phase=rx_string(event,"event",8);if(!strcmp(phase,"progress")){
        const char *stage=rx_string(event,"stage",16);
        assert(stage&&(!strcmp(stage,"write")||!strcmp(stage,"readback")));
        progress_events++;json_object_put(event);continue;}
        const char *path=rx_string(event,"path",4095);assert(path);
        if(!strcmp(phase,"created")){int fd=openat(root,path,O_RDONLY|O_NOFOLLOW);struct stat st;assert(fd>=0&&!fstat(fd,&st)&&st.st_size==0);close(fd);created++;}
        if(!strcmp(phase,"result")){results++;if(reject_result){close(request[1]);request[1]=-1;refused=1;json_object_put(event);continue;}}
        assert(request[1]>=0);send_ack(request[1],root,event,0);json_object_put(event);
    }
    if(request[1]>=0)close(request[1]);close(result[0]);int status=0;assert(waitpid(child,&status,0)==child&&WIFEXITED(status));
    int success=fixed?expected==actual:1;if(reject_result)success=0;assert((WEXITSTATUS(status)==0)==success);assert(created>=1);if(success)assert(results==1);if(reject_result)assert(refused&&results==1);
    int producer_status;assert(waitpid(producer,&producer_status,0)==producer);assert(WIFEXITED(producer_status)&&WEXITSTATUS(producer_status)==0);
    assert(progress_events<=(elapsed_clock_ms()-progress_started)/1000+1&&"write/readback progress exceeded its shared rate");
    assert(!unlinkat(root,"dev/27/2/payload/file",0));
    assert(!unlinkat(root,"dev/27/2/payload",AT_REMOVEDIR));assert(!unlinkat(root,"dev/27/2",AT_REMOVEDIR));assert(!unlinkat(root,"dev/27",AT_REMOVEDIR));assert(!unlinkat(root,"dev",AT_REMOVEDIR));close(root);assert(!rmdir(temporary));json_object_put(context.owner);
}

static void two_files_one_fifo(void) {
    char temporary[]="rootpxe-fifo-fixture.XXXXXX";assert(mkdtemp(temporary));puts(temporary);int root=open(temporary,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);assert(root>=0);assert(!mkdirat(root,"dev",0700));assert(!mkdirat(root,"dev/27",0700));assert(!mkdirat(root,"dev/27/2",0700));assert(!mkfifoat(root,"data",0600));
    int request[2],result[2];assert(!pipe(request)&&!pipe(result));struct storage_context context={0};strcpy(context.protocol,"nfs");strcpy(context.stage,"dev/27/2");strcpy(context.lock,".locks/key");strcpy(context.image_path,"image");context.data_write=1;context.parent=getpid();context.owner=json_tokener_parse("{\"taskType\":\"capture\"}");
    pid_t child=fork();assert(child>=0);if(!child){close(request[1]);close(result[0]);int data=openat(root,"data",O_RDONLY|O_NOFOLLOW);assert(data>=0);struct storage_fs fs={.root=root,.context=&context};assert(!rx_stat_fd(root,&fs.root_stat));for(int i=0;i<2;i++){struct json_object *c=command(&context,i?"dev/27/2/b":"dev/27/2/a",i?4:1,1,3);if(rx_command(&fs,c,request[0],data,result[1]))_exit(7);json_object_put(c);}close(data);close(result[1]);_exit(0);}
    close(request[0]);close(result[1]);int writer=openat(root,"data",O_WRONLY|O_NOFOLLOW);assert(writer>=0);write_bytes(writer,3);close(writer);int results=0;struct json_object *event;
    while((event=rx_read_json(result[0],65536,1))){int finished=!strcmp(rx_string(event,"event",8),"result");send_ack(request[1],root,event,0);json_object_put(event);if(finished&&++results==1){writer=openat(root,"data",O_WRONLY|O_NOFOLLOW);assert(writer>=0);write_bytes(writer,3);close(writer);}}
    assert(results==2);close(request[1]);close(result[0]);int status;assert(waitpid(child,&status,0)==child&&WIFEXITED(status)&&!WEXITSTATUS(status));assert(!unlinkat(root,"dev/27/2/a",0)&&!unlinkat(root,"dev/27/2/b",0));assert(!unlinkat(root,"dev/27/2",AT_REMOVEDIR)&&!unlinkat(root,"dev/27",AT_REMOVEDIR)&&!unlinkat(root,"dev",AT_REMOVEDIR)&&!unlinkat(root,"data",0));close(root);assert(!rmdir(temporary));json_object_put(context.owner);
}

static void read_case(int close_output, int truncate_source, int measure_progress) {
    int64_t progress_started=elapsed_clock_ms();
    char temporary[]="rootpxe-read-fixture.XXXXXX";
    assert(mkdtemp(temporary));
    puts(temporary);
    int root=open(temporary,O_RDONLY|O_DIRECTORY);
    assert(root>=0);
    assert(!mkdirat(root,"image",0700));
    int source=openat(root,"image/part.img",O_CREAT|O_RDWR|O_EXCL,0600);
    assert(source>=0);
    const size_t image_size=(measure_progress ? 16 : 2)*1024*1024;
    write_bytes(source,image_size);

    int request[2],result[2],data[2];
    assert(!pipe(request)&&!pipe(result)&&!pipe(data));
    struct storage_context context={.parent=getpid()};
    strcpy(context.image_path,"image");
    context.owner=json_tokener_parse("{\"taskType\":\"deploy\"}");
    pid_t child=fork();
    assert(child>=0);
    if(!child){
        close(request[1]);close(result[0]);close(data[0]);close(source);
        signal(SIGPIPE,SIG_IGN);
        struct storage_fs fs={.root=root,.context=&context};
        assert(!rx_stat_fd(root,&fs.root_stat));
        struct json_object *c=command(&context,"image/part.img",1,0,0);
        json_object_object_add(c,"operation",json_object_new_string("read"));
        int rc=rx_command(&fs,c,request[0],data[1],result[1]);
        json_object_put(c);
        _exit(rc?7:0);
    }
    close(request[0]);close(result[1]);close(data[1]);
    struct json_object *event=rx_read_json(result[0],65536,1);
    assert(event&&!strcmp(rx_string(event,"event",8),"intent"));
    send_ack(request[1],root,event,0);
    json_object_put(event);

    int missing_progress=0;
    if(close_output){
        close(data[0]);
    }else if(truncate_source){
        /* At least one byte has passed the intent proof before the source shrinks. */
        unsigned char first;
        assert(read(data[0],&first,1)==1);
        assert(!ftruncate(source,0));
    }else if(!measure_progress){
        /* Keep the output FIFO full for longer than the shell's control timeout.
         * A heartbeat must describe real bytes written and must precede 30 s. */
        struct timespec started, now;
        assert(!clock_gettime(CLOCK_MONOTONIC,&started));
        do {
            struct pollfd pending={.fd=result[0],.events=POLLIN};
            if(poll(&pending,1,15000)!=1){
                missing_progress=1;
                break;
            }
            event=rx_read_json(result[0],65536,1);
            assert(event&&!strcmp(rx_string(event,"event",8),"progress"));
            assert(!strcmp(rx_string(event,"stage",16),"read"));
            const char *bytes=rx_string(event,"bytes",20);
            assert(bytes&&strtoull(bytes,NULL,10)>0&&strtoull(bytes,NULL,10)<image_size);
            json_object_put(event);
            assert(!clock_gettime(CLOCK_MONOTONIC,&now));
        }while((now.tv_sec-started.tv_sec)*1000+(now.tv_nsec-started.tv_nsec)/1000000<31000);
    }
    size_t received=0;
    if(missing_progress){
        kill(child,SIGTERM);
        close(data[0]);
    }else if(!close_output){
        unsigned char bytes[16384];
        while(received<image_size){
            ssize_t n=read(data[0],bytes,sizeof(bytes));
            assert(n>=0);
            if(!n)break;
            for(ssize_t i=0;i<n;i++)assert(bytes[i]=='x');
            received+=(size_t)n;
        }
        close(data[0]);
    }
    int results=0,progress_events=0;
    if(!missing_progress){
        while((event=rx_read_json(result[0],65536,1))){
            const char *phase=rx_string(event,"event",8);
            if(!strcmp(phase,"result")){
                results++;
                send_ack(request[1],root,event,0);
            }else{
                assert(!strcmp(phase,"progress"));
                progress_events++;
            }
            json_object_put(event);
        }
    }
    close(request[1]);close(result[0]);
    int status;
    assert(waitpid(child,&status,0)==child);
    close(source);
    assert(!unlinkat(root,"image/part.img",0)&&!unlinkat(root,"image",AT_REMOVEDIR));
    close(root);
    assert(!rmdir(temporary));
    json_object_put(context.owner);
    assert(!missing_progress&&"a full output FIFO stopped local progress");
    if(measure_progress)assert(progress_events<=(elapsed_clock_ms()-progress_started)/1000+1&&"read progress exceeded its rate");
    assert(WIFEXITED(status));
    if(close_output||truncate_source){
        assert(WEXITSTATUS(status)==7&&results==0&&received<image_size);
    }else{
        assert(WEXITSTATUS(status)==0&&results==1&&received==image_size);
    }
}

static void read_proof_case(size_t original_size, size_t replacement_size, int at_stat) {
    char temporary[] = "rootpxe-proof-fixture.XXXXXX";
    assert(mkdtemp(temporary));
    puts(temporary);
    int root = open(temporary, O_RDONLY | O_DIRECTORY);
    assert(root >= 0 && !mkdirat(root, "image", 0700));
    int source = openat(root, "image/part.img", O_CREAT | O_RDWR | O_EXCL, 0600);
    assert(source >= 0);
    write_bytes(source, original_size);
    struct stat source_stat;
    assert(!fstat(source, &source_stat));
    int request[2], result[2], data[2];
    assert(!pipe(request) && !pipe(result) && !pipe(data));
    struct storage_context context = {.parent=getpid()};
    strcpy(context.image_path, "image");
    context.owner = json_tokener_parse("{\"taskType\":\"deploy\"}");
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        close(request[1]); close(result[0]); close(data[0]);
        struct storage_fs fs = {.root=root, .context=&context};
        assert(!rx_stat_fd(root, &fs.root_stat));
        if (at_stat) {
            change_fd = source;
            change_ino = source_stat.st_ino;
            change_size = (off_t)replacement_size;
            change_at_stat = at_stat;
            source_stats = 0;
        }
        struct json_object *c = command(&context, "image/part.img", 1, 0, 0);
        json_object_object_add(c, "operation", json_object_new_string("read"));
        int rc = rx_command(&fs, c, request[0], data[1], result[1]);
        if (at_stat) assert(source_stats >= at_stat);
        json_object_put(c);
        close(data[1]); close(result[1]);
        _exit(rc ? 7 : 0);
    }
    close(request[0]); close(result[1]); close(data[1]);
    int results = 0;
    struct json_object *event;
    while ((event = rx_read_json(result[0], 65536, 1))) {
        const char *phase = rx_string(event, "event", 8);
        assert(phase && (!strcmp(phase, "intent") || !strcmp(phase, "result")));
        if (!strcmp(phase, "result")) results++;
        send_ack(request[1], root, event, 0);
        json_object_put(event);
    }
    unsigned char bytes[32];
    size_t received = 0;
    ssize_t n;
    while ((n = read(data[0], bytes, sizeof(bytes))) > 0) received += (size_t)n;
    assert(n == 0);
    close(data[0]); close(request[1]); close(result[0]);
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status));
    close(source);
    assert(!unlinkat(root, "image/part.img", 0) && !unlinkat(root, "image", AT_REMOVEDIR));
    close(root);
    assert(!rmdir(temporary));
    json_object_put(context.owner);
    if (at_stat) {
        assert(WEXITSTATUS(status) == 7 && results == 0 && received == 0 &&
               "changed source escaped the original intent proof");
    } else {
        assert(WEXITSTATUS(status) == 0 && results == 1 && received == original_size);
    }
}

static int benchmark_helper(const char *root_path, const char *request_path,
                            const char *data_path, const char *result_path) {
    int root = open(root_path, O_RDONLY | O_DIRECTORY);
    assert(root >= 0);
    struct storage_context context = {.parent=getppid()};
    strcpy(context.image_path, "image");
    context.owner = json_tokener_parse("{\"taskType\":\"deploy\"}");
    int request = open(request_path, O_RDONLY);
    int data = open(data_path, O_WRONLY);
    int result = open(result_path, O_WRONLY);
    assert(request >= 0 && data >= 0 && result >= 0);
    struct storage_fs fs = {.root=root,.context=&context};
    assert(!rx_stat_fd(root, &fs.root_stat));
    struct json_object *command = rx_read_json(request, RX_COMMAND_MAX, 1);
    assert(command);
    int rc = rx_command(&fs, command, request, data, result);
    if (!rc) {
        struct json_object *done = json_tokener_parse("{\"event\":\"done\",\"sequence\":\"2\"}");
        rc = rx_emit(result, done);
        json_object_put(done);
    }
    json_object_put(command);
    json_object_put(context.owner);
    close(request);
    close(result);
    close(data);
    close(root);
    return rc ? 7 : 0;
}

int main(int argc,char **argv) {
    if (argc == 6 && !strcmp(argv[1], "benchmark-helper")) {
        return benchmark_helper(argv[2], argv[3], argv[4], argv[5]);
    }
    if (argc == 3 && !strcmp(argv[1], "benchmark-proof")) {
        int root = open(argv[2], O_RDONLY | O_DIRECTORY);
        assert(root >= 0);
        struct json_object *proof = proof_for(root, "image/part.img");
        assert(!rx_emit(STDOUT_FILENO, proof));
        json_object_put(proof);
        close(root);
        return 0;
    }
    if(argc==2&&!strcmp(argv[1],"read")){
        read_case(0,0,0);
        read_case(1,0,0);
        read_case(0,1,0);
        return 0;
    }
    if(argc==2&&!strcmp(argv[1],"progress")){
        read_case(0,0,1);
        return 0;
    }
    if(argc==2&&!strcmp(argv[1],"read-proof")){
        read_proof_case(0,0,0);
        read_proof_case(4,4,0);
        for (int at_stat=1;at_stat<=2;at_stat++) {
            read_proof_case(4,2,at_stat);
            read_proof_case(4,8,at_stat);
            read_proof_case(4,0,at_stat);
            read_proof_case(0,8,at_stat);
            read_proof_case(4,4,at_stat);
        }
        return 0;
    }
    one_case(4,3,1,0);one_case(3,4,1,0);one_case(3,3,1,0);one_case(3,3,1,1);one_case(0,3,0,1);one_case(0,209715207,0,0);two_files_one_fifo();return 0;
}
