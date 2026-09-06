/* EFI boot-variable identity repair.  This unit intentionally has no
 * dependency on the Windows hive repair context. */
#define _GNU_SOURCE
#include "efi-identities.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <limits.h>
#include <stdint.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define EFI_GUID "8be4df61-93ca-11d2-aa0d-00e098032b8c"
#define MAX_MAPS 64
#define MAX_VARS 256

typedef struct {
    char binding[128], table[4], olddisk[64], newdisk[64], oldpart[64], newpart[64];
    uint32_t part;
    uint64_t oldoff, newoff, oldsize, newsize, oldsec, newsec;
} efi_map;
typedef struct {
    char root[PATH_MAX], varfs[PATH_MAX], planid[80], stage[PATH_MAX];
    efi_map maps[MAX_MAPS]; size_t nmaps;
    char vars[MAX_VARS][128]; size_t nvars;
    size_t matched;
} efi_ctx;

static void err(const char *s) { fprintf(stderr, "rootpxe-offline-identities: efi-repair: %s\n", s); }
static int is_regular(const char *p) { struct stat st; return lstat(p, &st) == 0 && S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode); }
static int is_dir(const char *p) { struct stat st; return lstat(p, &st) == 0 && S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode); }
static int join(char *o, size_t n, const char *a, const char *b) { return snprintf(o,n,"%s/%s",a,b) >= 0 && (size_t)snprintf(o,n,"%s/%s",a,b) < n ? 0 : -1; }
static uint16_t get16(const unsigned char *p) { return (uint16_t)p[0] | ((uint16_t)p[1]<<8); }
static uint32_t get32(const unsigned char *p) { return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }
static uint64_t get64(const unsigned char *p) { uint64_t v=0; int i; for(i=7;i>=0;i--) v=(v<<8)|p[i]; return v; }
static void put64(unsigned char *p,uint64_t v) { int i; for(i=0;i<8;i++){p[i]=(unsigned char)v;v>>=8;} }
static void put32(unsigned char *p,uint32_t v) { int i; for(i=0;i<4;i++){p[i]=(unsigned char)v;v>>=8;} }

static int read_all(const char *p, unsigned char **out, size_t *len) {
    int fd = -1; struct stat st; unsigned char *b; size_t at=0; ssize_t r=0;
    *out = NULL; *len = 0;
    if (!is_regular(p) || (fd=open(p,O_RDONLY|O_CLOEXEC|O_NOFOLLOW))<0 || fstat(fd,&st)<0 || st.st_size < 0) { if(fd>=0)close(fd); return -1; }
    if ((uintmax_t)st.st_size > SIZE_MAX-1 || !(b=malloc((size_t)st.st_size+1))) { close(fd); return -1; }
    while(at<(size_t)st.st_size && (r=read(fd,b+at,(size_t)st.st_size-at))>0) at+=(size_t)r;
    if(r<0||fstat(fd,&st)<0||at!=(size_t)st.st_size||close(fd)<0){free(b);return -1;} b[at]='\0';*out=b;*len=at;return 0;
}
static int write_private(const char *p,const void *b,size_t n) {
    char t[PATH_MAX], parent[PATH_MAX], *slash; int fd, dfd; ssize_t w; if(snprintf(t,sizeof(t),"%s.tmp.%ld",p,(long)getpid()) >= (int)sizeof(t)) return -1;
    fd=open(t,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600); if(fd<0)return -1;
    w=write(fd,b,n); if(w!=(ssize_t)n||fsync(fd)<0||close(fd)<0){unlink(t);return -1;} if(rename(t,p)<0){unlink(t);return -1;}
    if (strlen(p) >= sizeof(parent)) return -1;
    strcpy(parent,p); slash=strrchr(parent,'/'); if(!slash) return -1;
    *slash='\0'; dfd=open(parent,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(dfd<0||fsync(dfd)<0){if(dfd>=0)close(dfd);return -1;} return close(dfd);
}
static int ensure_dir(const char *p) { if (is_dir(p)) return chmod(p,0700); if(mkdir(p,0700)<0)return -1; return 0; }
static int stage_path(efi_ctx *c,const char *name,char *out,size_t n) { return join(out,n,c->stage,name); }
static int good_planid(const char *s) { size_t i,n=strlen(s); if(!n||n>=80||!strcmp(s,".")||!strcmp(s,".."))return 0; for(i=0;i<n;i++)if(!((s[i]>='a'&&s[i]<='z')||(s[i]>='A'&&s[i]<='Z')||(s[i]>='0'&&s[i]<='9')||s[i]=='_'||s[i]=='-'||s[i]=='.'))return 0;return 1; }
static int safe_root(const char *p) { char q[PATH_MAX], *s; size_t n;if(!p||(n=strlen(p))<2||p[0]!='/'||n>=sizeof(q)||strstr(p,"//")||strstr(p,"/./")||strstr(p,"/../")||(n>=2&&!strcmp(p+n-2,"/."))||(n>=3&&!strcmp(p+n-3,"/..")))return 0;strcpy(q,p);for(s=q+1;*s;s++)if(*s=='/'){*s='\0';if(!is_dir(q))return 0;*s='/';}return is_dir(q); }
static int hex(int x){return (x>='0'&&x<='9')?x-'0':(x>='a'&&x<='f')?x-'a'+10:(x>='A'&&x<='F')?x-'A'+10:-1;}
static int guid(const char *s,unsigned char out[16]) {
    int i, a, b, k = 0;
    unsigned char be[16]; static const int dash[] = {8,13,18,23};
    if (strlen(s) != 36) return -1;
    for (i = 0; i < 4; i++) if (s[dash[i]] != '-') return -1;
    for (i = 0; s[i];) {
        if (s[i] == '-') { i++; continue; }
        a = hex((unsigned char)s[i++]); b = hex((unsigned char)s[i++]);
        if (a < 0 || b < 0 || k == 16) return -1;
        be[k++] = (unsigned char)((a << 4) | b);
    }
    if (k != 16) return -1;
    out[0]=be[3]; out[1]=be[2]; out[2]=be[1]; out[3]=be[0];
    out[4]=be[5]; out[5]=be[4]; out[6]=be[7]; out[7]=be[6];
    memcpy(out+8,be+8,8); return 0;
}
static int disk_sig(const char *s,uint32_t *v){char *e;unsigned long x;if(strlen(s)!=8)return -1;errno=0;x=strtoul(s,&e,16);if(errno||*e||x>UINT32_MAX)return -1;*v=(uint32_t)x;return 0;}

typedef struct { char *s; size_t n,cap; } sb;
static int sbadd(sb *b,const char *s){size_t n=strlen(s),c;if(b->n+n+1>b->cap){c=b->cap?b->cap*2:256;while(c<b->n+n+1)c*=2; b->s=realloc(b->s,c);if(!b->s)return -1;b->cap=c;}memcpy(b->s+b->n,s,n+1);b->n+=n;return 0;}
static int cmpstr(const void*a,const void*b){return strcmp(*(char*const*)a,*(char*const*)b);}
static int canon(json_object *o,sb *b){enum json_type t=json_object_get_type(o);size_t i,n;char **keys;const char *x;
 if(t==json_type_object){if(sbadd(b,"{"))return -1;n=json_object_object_length(o);keys=calloc(n?n:1,sizeof(*keys));if(!keys)return -1;i=0;json_object_object_foreach(o,k,unused){(void)unused;keys[i++]=(char*)k;}qsort(keys,n,sizeof(*keys),cmpstr);for(i=0;i<n;i++){if(i&&sbadd(b,",")){free(keys);return -1;}/* key quoting */{json_object *z=json_object_new_string(keys[i]);int q=sbadd(b,json_object_to_json_string_ext(z,JSON_C_TO_STRING_PLAIN));json_object_put(z);if(q||sbadd(b,":")){free(keys);return -1;}}if(canon(json_object_object_get(o,keys[i]),b)){free(keys);return -1;}}free(keys);return sbadd(b,"}");}
 if(t==json_type_array){if(sbadd(b,"["))return -1;n=json_object_array_length(o);for(i=0;i<n;i++){if(i&&sbadd(b,","))return -1;if(canon(json_object_array_get_idx(o,i),b))return -1;}return sbadd(b,"]");} x=json_object_to_json_string_ext(o,JSON_C_TO_STRING_PLAIN);return sbadd(b,x); }
static int load_json(const char *p,json_object **out,char **normal){unsigned char *raw=NULL;size_t n,end;sb b={0};json_object *o;json_tokener *t;if(read_all(p,&raw,&n)||!n)return -1;t=json_tokener_new();if(!t){free(raw);return -1;}o=json_tokener_parse_ex(t,(char*)raw,(int)n);end=(size_t)t->char_offset;while(end<n&&isspace(raw[end]))end++;if(json_tokener_get_error(t)!=json_tokener_success||!o||end!=n){if(o)json_object_put(o);json_tokener_free(t);free(raw);return -1;}json_tokener_free(t);free(raw);if(canon(o,&b)){json_object_put(o);free(b.s);return -1;}*out=o;*normal=b.s;return 0;}
static int field(json_object *o,const char *k,json_object **v){return json_object_object_get_ex(o,k,v)&&*v;}
static int strfield(json_object *o,const char*k,char *d,size_t n){json_object*v;if(!field(o,k,&v)||json_object_get_type(v)!=json_type_string||strlen(json_object_get_string(v))>=n)return -1;strcpy(d,json_object_get_string(v));return 0;}
static int u64field(json_object*o,const char*k,uint64_t*d){json_object*v;int64_t x;if(!field(o,k,&v)||json_object_get_type(v)!=json_type_int)return -1;x=json_object_get_int64(v);if(x<=0)return -1;*d=(uint64_t)x;return 0;}
static int u32field(json_object*o,const char*k,uint32_t*d){uint64_t x;if(u64field(o,k,&x)||x>UINT32_MAX)return -1;*d=(uint32_t)x;return 0;}
static int plan_has(json_object *plan, efi_map *m)
{
    json_object *topology, *tops, *news, *old, *nw, *ops, *nps, *op, *np;
    size_t i, j, k;
    uint32_t number;
    char target[PATH_MAX], part_target[PATH_MAX], id[128], pid[64];
    int found = 0;

    if (!field(plan, "topology", &topology) || !field(topology, "disks", &tops) ||
        !field(plan, "disks", &news) || json_object_get_type(tops) != json_type_array ||
        json_object_get_type(news) != json_type_array)
        return -1;
    for (i = 0; i < json_object_array_length(tops); i++) {
        old = json_object_array_get_idx(tops, i);
        if (json_object_get_type(old) != json_type_object ||
            strfield(old, "targetBinding", id, sizeof(id)) || strcmp(id, m->binding))
            continue;
        if (found++) return -1;
        if (strfield(old, "targetDevice", target, sizeof(target)) ||
            strfield(old, "partitionTable", id, sizeof(id)) || strcmp(id, m->table) ||
            strfield(old, "oldDiskId", id, sizeof(id)) || strcmp(id, m->olddisk) ||
            !field(old, "partitions", &ops) || json_object_get_type(ops) != json_type_array)
            return -1;
        op = NULL;
        for (j = 0; j < json_object_array_length(ops); j++) {
            json_object *x = json_object_array_get_idx(ops, j);
            if (!u32field(x, "number", &number) && number == m->part) {
                if (op) return -1;
                op = x;
            }
        }
        if (!op || strfield(op, "oldPartitionId", id, sizeof(id)) || strcmp(id, m->oldpart) ||
            strfield(op, "targetDevice", part_target, sizeof(part_target))) return -1;
        nw = NULL;
        for (j = 0; j < json_object_array_length(news); j++) {
            json_object *x = json_object_array_get_idx(news, j);
            if (!strfield(x, "targetDevice", id, sizeof(id)) && !strcmp(id, target)) {
                if (nw) return -1;
                nw = x;
            }
        }
        if (!nw || !field(nw, "partitions", &nps) || json_object_get_type(nps) != json_type_array)
            return -1;
        if ((!strcmp(m->table, "gpt") &&
             (strfield(nw, "diskGuid", id, sizeof(id)) || strcmp(id, m->newdisk))) ||
            (!strcmp(m->table, "mbr") &&
             (strfield(nw, "diskSignature", id, sizeof(id)) || strcmp(id, m->newdisk))))
            return -1;
        np = NULL;
        for (k = 0; k < json_object_array_length(nps); k++) {
            json_object *x = json_object_array_get_idx(nps, k);
            if (!strfield(x, "targetDevice", id, sizeof(id)) && !strcmp(id, part_target)) {
                if (np) return -1;
                np = x;
            }
        }
        if (!np || (!strcmp(m->table, "gpt") &&
                    (strfield(np, "partitionGuid", pid, sizeof(pid)) || strcmp(pid, m->newpart))))
            return -1;
    }
    return found == 1 ? 0 : -1;
}
static int parse_inputs(efi_ctx*c,const char*mf,const char*pf,char **mn,char**pn){json_object*m=NULL,*p=NULL,*plan,*vs,*v,*bound;size_t i;int64_t ver;
 if(load_json(mf,&m,mn)||load_json(pf,&p,pn)) goto bad;
 if(!field(m,"version",&v)||json_object_get_type(v)!=json_type_int||(ver=json_object_get_int64(v))!=1||strfield(m,"stateRoot",c->root,sizeof(c->root))||!safe_root(c->root)) goto bad;
 if(!field(m,"efiVarFs",&v)||json_object_get_type(v)!=json_type_string) goto bad;
#ifdef ROOTPXE_EFI_TEST
 if(strlen(json_object_get_string(v))>=sizeof(c->varfs)) goto bad;
 strcpy(c->varfs,json_object_get_string(v));
#else
 if(strcmp(json_object_get_string(v),"/sys/firmware/efi/efivars")) goto bad;
 strcpy(c->varfs,"/sys/firmware/efi/efivars");
#endif
 if(!field(m,"volumes",&vs)||json_object_get_type(vs)!=json_type_array||json_object_array_length(vs)>MAX_MAPS)goto bad;
 if(!field(p,"plan",&plan)||json_object_get_type(plan)!=json_type_object||strfield(plan,"planId",c->planid,sizeof(c->planid))||!good_planid(c->planid))goto bad;
 if(!field(p,"planHash",&v)||json_object_get_type(v)!=json_type_string||strlen(json_object_get_string(v))!=64||!field(p,"attempt",&v)||json_object_get_type(v)!=json_type_int||json_object_get_int64(v)<0)goto bad;
 c->nmaps=json_object_array_length(vs);for(i=0;i<c->nmaps;i++){efi_map*x=&c->maps[i];v=json_object_array_get_idx(vs,i);if(json_object_get_type(v)!=json_type_object||strfield(v,"diskBinding",x->binding,sizeof(x->binding))||strfield(v,"partitionTable",x->table,sizeof(x->table))||(strcmp(x->table,"gpt")&&strcmp(x->table,"mbr"))||strfield(v,"oldDiskId",x->olddisk,sizeof(x->olddisk))||strfield(v,"newDiskId",x->newdisk,sizeof(x->newdisk))||strfield(v,"oldPartitionGuid",x->oldpart,sizeof(x->oldpart))||u32field(v,"partitionNumber",&x->part)||u64field(v,"oldOffsetBytes",&x->oldoff)||u64field(v,"newOffsetBytes",&x->newoff)||u64field(v,"oldSizeBytes",&x->oldsize)||u64field(v,"newSizeBytes",&x->newsize)||u64field(v,"oldLogicalSectorBytes",&x->oldsec)||u64field(v,"newLogicalSectorBytes",&x->newsec)||x->oldoff%x->oldsec||x->newoff%x->newsec||x->oldsize%x->oldsec||x->newsize%x->newsec)goto bad;if(!strcmp(x->table,"gpt")){if(strfield(v,"newPartitionGuid",x->newpart,sizeof(x->newpart))||guid(x->oldpart,(unsigned char[16]){0})||guid(x->newpart,(unsigned char[16]){0}))goto bad;}else if(disk_sig(x->olddisk,&(uint32_t){0})||disk_sig(x->newdisk,&(uint32_t){0}))goto bad;if(plan_has(plan,x))goto bad;}
 bound=json_object_new_object();if(!bound)goto bad;json_object_object_add(bound,"plan",json_object_get(plan));if(!field(p,"planHash",&v)){json_object_put(bound);goto bad;}json_object_object_add(bound,"planHash",json_object_get(v));free(*pn);*pn=NULL;{sb x={0};if(canon(bound,&x)){json_object_put(bound);goto bad;}*pn=x.s;}json_object_put(bound);json_object_put(m);json_object_put(p);return 0;bad:if(m)json_object_put(m);if(p)json_object_put(p);free(*mn);free(*pn);*mn=*pn=NULL;return -1;}

static int check_varfs(efi_ctx*c){
#ifndef ROOTPXE_EFI_TEST
 FILE*f=fopen("/proc/mounts","r");char a[PATH_MAX],b[PATH_MAX],t[64];int ok=0;if(!f)return -1;while(fscanf(f,"%4095s %4095s %63s%*[^\n]\n",a,b,t)==3)if(!strcmp(b,c->varfs)&&!strcmp(t,"efivarfs")){ok=1;break;}fclose(f);if(!ok)return 1;
#endif
 return is_dir(c->varfs)?0:-1;
}
static int valid_name(const char*s){size_t n=strlen(s);if(n!=4+4+1+36||strncmp(s,"Boot",4)||s[8]!='-')return 0;for(size_t i=4;i<8;i++)if(hex((unsigned char)s[i])<0)return 0;return !strcmp(s+9,EFI_GUID);}
static int fix_option(efi_ctx*c,unsigned char*b,size_t n,size_t*hits){size_t q=6,end,node;uint16_t plen;if(n<12)return -1;plen=get16(b+4);while(q+1<n&&(b[q]||b[q+1]))q+=2;if(q+1>=n)return -1;q+=2;if(plen<4||plen>n-q)return -1;end=q+plen;for(node=q;node<end;){size_t z;if(end-node<4)return -1;z=get16(b+node+2);if(z<4||z>end-node)return -1;if(b[node]==0x7f){if(node+z!=end||b[node+1]!=0xff||z!=4)return -1;}else if(b[node]>6)return -1;else if(b[node]==4&&b[node+1]==1){efi_map*found=NULL;size_t i;uint64_t st,sz;if(z!=42||!((b[node+40]==2&&b[node+41]==2)||(b[node+40]==1&&b[node+41]==1)))return -1;st=get64(b+node+8);sz=get64(b+node+16);for(i=0;i<c->nmaps;i++){efi_map*x=&c->maps[i];int match=0;if(x->part!=get32(b+node+4)||st!=x->oldoff/x->oldsec||sz!=x->oldsize/x->oldsec)continue;if(!strcmp(x->table,"gpt")&&b[node+40]==2&&b[node+41]==2){unsigned char g[16];if(!guid(x->oldpart,g)&&!memcmp(g,b+node+24,16))match=1;}if(!strcmp(x->table,"mbr")&&b[node+40]==1&&b[node+41]==1){uint32_t d;if(!disk_sig(x->olddisk,&d)&&d==get32(b+node+24))match=1;}if(match){if(found)return -1;found=x;}}if(found){if(!strcmp(found->table,"gpt")){unsigned char g[16];if(guid(found->newpart,g))return -1;memcpy(b+node+24,g,16);}else{uint32_t d;if(disk_sig(found->newdisk,&d))return -1;put32(b+node+24,d);}put64(b+node+8,found->newoff/found->newsec);put64(b+node+16,found->newsize/found->newsec);(*hits)++;}}node+=z;}return node==end?0:-1;}
static int transform(efi_ctx*c,unsigned char*b,size_t n,size_t*hits){if(n<4)return -1;return fix_option(c,b+4,n-4,hits);}
static int save_inputs(efi_ctx*c,const char*mn,const char*pn){char p[PATH_MAX];if(stage_path(c,"manifest.json",p,sizeof(p))||write_private(p,mn,strlen(mn)))return -1;if(stage_path(c,"plan.json",p,sizeof(p))||write_private(p,pn,strlen(pn)))return -1;return 0;}
static int stage_ok(efi_ctx *c, const char *mn, const char *pn)
{
    char p[PATH_MAX]; unsigned char *b = NULL; size_t n = 0; int ok;
    if (!safe_root(c->stage) || stage_path(c, "manifest.json", p, sizeof(p)) || read_all(p, &b, &n)) return -1;
    ok = n == strlen(mn) && !memcmp(b, mn, n); free(b); b = NULL;
    if (!ok || stage_path(c, "plan.json", p, sizeof(p)) || read_all(p, &b, &n)) return -1;
    ok = n == strlen(pn) && !memcmp(b, pn, n); free(b);
    return ok ? 0 : -1;
}
static int result(const char*p,int available,size_t matched,size_t updated,int verified){char b[256];int n=snprintf(b,sizeof(b),"{\"version\":1,\"efi\":{\"available\":%s,\"matched\":%zu,\"updated\":%zu,\"verified\":%s}}\n",available?"true":"false",matched,updated,verified?"true":"false");return n<0||write_private(p,b,(size_t)n);}
static int load_vars(efi_ctx *c);
static int preflight(efi_ctx *c, const char *mn, const char *pn, size_t *updated)
{
    DIR *d; struct dirent *e; char base[PATH_MAX], planbase[PATH_MAX], p[PATH_MAX], sp[PATH_MAX], name[160], list[32768];
    size_t li = 0;
    if (ensure_dir(c->root) || join(base, sizeof(base), c->root, ".rootpxe-offline-identities") || ensure_dir(base) || join(planbase, sizeof(planbase), base, c->planid) || ensure_dir(planbase) || join(c->stage, sizeof(c->stage), planbase, "efi") || ensure_dir(c->stage)) return -1;
    if (stage_path(c, "manifest.json", sp, sizeof(sp))) return -1;
    if (is_regular(sp)) { if (stage_ok(c, mn, pn) || load_vars(c)) return -1; c->matched = c->nvars; *updated = 0; return 0; }
    d = opendir(c->varfs); if (!d) return -1;
    while ((e = readdir(d))) {
        unsigned char *orig = NULL, *cand = NULL; size_t n = 0, h = 0;
        if (!valid_name(e->d_name)) continue;
        if (c->nvars >= MAX_VARS || join(p, sizeof(p), c->varfs, e->d_name) || read_all(p, &orig, &n)) goto fail;
        cand = malloc(n); if (!cand) goto fail; memcpy(cand, orig, n);
        if (transform(c, cand, n, &h)) goto fail;
        if (h) {
            if (snprintf(name, sizeof(name), "%zu.orig", c->nvars) >= (int)sizeof(name) || stage_path(c, name, sp, sizeof(sp)) || write_private(sp, orig, n) || snprintf(name, sizeof(name), "%zu.cand", c->nvars) >= (int)sizeof(name) || stage_path(c, name, sp, sizeof(sp)) || write_private(sp, cand, n) || li + strlen(e->d_name) + 2 >= sizeof(list)) goto fail;
            strcpy(c->vars[c->nvars++], e->d_name); li += (size_t)sprintf(list + li, "%s\n", e->d_name); c->matched += h;
        }
        free(orig); free(cand); continue;
fail: free(orig); free(cand); closedir(d); return -1;
    }
    closedir(d);
    { char vars[33024]; int h = snprintf(vars, sizeof(vars), "count=%zu\n", c->nvars); if (h < 0 || (size_t)h + li >= sizeof(vars)) return -1; memcpy(vars + h, list, li); if (stage_path(c, "vars", sp, sizeof(sp)) || write_private(sp, vars, (size_t)h + li) || save_inputs(c, mn, pn)) return -1; }
    *updated = 0; return 0;
}
static int load_vars(efi_ctx *c)
{
    char p[PATH_MAX], *q, *save, *end;
    unsigned char *b = NULL;
    size_t n, expected, i;
    if (stage_path(c, "vars", p, sizeof(p)) || read_all(p, &b, &n)) return -1;
    if (n < 8 || memcmp(b, "count=", 6) || b[n - 1] != '\n') goto bad;
    errno = 0; expected = strtoul((char *)b + 6, &end, 10);
    if (errno || end == (char *)b + 6 || *end != '\n' || expected > MAX_VARS) goto bad;
    c->nvars = 0;
    for (q = strtok_r(end + 1, "\n", &save); q; q = strtok_r(NULL, "\n", &save)) {
        if (!valid_name(q) || c->nvars >= expected) goto bad;
        for (i = 0; i < c->nvars; i++) if (!strcmp(c->vars[i], q)) goto bad;
        strcpy(c->vars[c->nvars++], q);
    }
    if (c->nvars != expected) goto bad;
    for (i = 0; i < expected + 1; i++) {
        char op[PATH_MAX], cp[PATH_MAX], nm[32];
        if (snprintf(nm, sizeof(nm), "%zu.orig", i) >= (int)sizeof(nm) || stage_path(c, nm, op, sizeof(op)) || snprintf(nm, sizeof(nm), "%zu.cand", i) >= (int)sizeof(nm) || stage_path(c, nm, cp, sizeof(cp))) goto bad;
        if (i == expected) { if (is_regular(op) || is_regular(cp)) goto bad; }
        else if (!is_regular(op) || !is_regular(cp)) goto bad;
    }
    free(b); return 0;
bad:
    free(b); return -1;
}
static int validate_stage_candidates(efi_ctx *c)
{
    size_t i;
    for (i = 0; i < c->nvars; i++) {
        char op[PATH_MAX], cp[PATH_MAX], nm[32];
        unsigned char *orig = NULL, *cand = NULL, *check = NULL;
        size_t on = 0, cn = 0, hits = 0;
        if (snprintf(nm, sizeof(nm), "%zu.orig", i) >= (int)sizeof(nm) || stage_path(c, nm, op, sizeof(op)) || snprintf(nm, sizeof(nm), "%zu.cand", i) >= (int)sizeof(nm) || stage_path(c, nm, cp, sizeof(cp)) || read_all(op, &orig, &on) || read_all(cp, &cand, &cn) || !(check = malloc(on))) goto fail;
        memcpy(check, orig, on);
        if (transform(c, check, on, &hits) || !hits || cn != on || memcmp(check, cand, on)) goto fail;
        free(orig); free(cand); free(check); continue;
fail:
        free(orig); free(cand); free(check); return -1;
    }
    return 0;
}
static int phase_apply_verify(efi_ctx *c, int apply, size_t *updated)
{
    size_t i;
    if (validate_stage_candidates(c)) return -1;
    for (i = 0; i < c->nvars; i++) {
        char vp[PATH_MAX], op[PATH_MAX], cp[PATH_MAX], nm[32];
        unsigned char *cur = NULL, *orig = NULL, *cand = NULL;
        size_t cn = 0, on = 0, nn = 0;
        int fd;
        ssize_t w;
        if (join(vp, sizeof(vp), c->varfs, c->vars[i]) ||
            snprintf(nm, sizeof(nm), "%zu.orig", i) >= (int)sizeof(nm) ||
            stage_path(c, nm, op, sizeof(op)) ||
            snprintf(nm, sizeof(nm), "%zu.cand", i) >= (int)sizeof(nm) ||
            stage_path(c, nm, cp, sizeof(cp)) || read_all(vp, &cur, &cn) ||
            read_all(op, &orig, &on) || read_all(cp, &cand, &nn))
            goto fail;
        if (apply && cn == nn && !memcmp(cur, cand, cn)) {
            /* A prior partial apply completed this variable. */
        } else if (apply && cn == on && !memcmp(cur, orig, cn)) {
            fd = open(vp, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
            w = fd < 0 ? -1 : write(fd, cand, nn);
            if (fd >= 0) close(fd);
            if (w != (ssize_t)nn) goto fail;
            free(cur); cur = NULL;
            if (read_all(vp, &cur, &cn) || cn != nn || memcmp(cur, cand, nn)) goto fail;
            (*updated)++;
        } else if (!apply && cn == nn && !memcmp(cur, cand, cn)) {
            /* verify accepts only the exact prepared candidate. */
        } else goto fail;
        free(cur); free(orig); free(cand);
        continue;
fail:
        free(cur); free(orig); free(cand);
        return -1;
    }
    return 0;
}
int rootpxe_efi_main(int argc,char**argv){const char *mf=NULL,*pf=NULL,*rf=NULL,*ph=NULL;efi_ctx c={0};char *mn=NULL,*pn=NULL;size_t updated=0;int i,avail,rc=2;for(i=1;i+1<argc;i+=2){if(!strcmp(argv[i],"--manifest"))mf=argv[i+1];else if(!strcmp(argv[i],"--plan"))pf=argv[i+1];else if(!strcmp(argv[i],"--result"))rf=argv[i+1];else if(!strcmp(argv[i],"--phase"))ph=argv[i+1];else{err("未知参数");return 2;}}if(!mf||!pf||!rf||!ph||i!=argc||!is_regular(mf)||!is_regular(pf)){err("用法: efi-repair --manifest FILE --plan FILE --result FILE --phase preflight|apply|verify");return 2;}if(parse_inputs(&c,mf,pf,&mn,&pn)){err("manifest 或 plan 不符合 EFI v1 契约");goto out;}avail=check_varfs(&c);if(avail==1){rc=result(rf,0,0,0,0)?2:0;goto out;}if(avail){err("efivarfs 不可用或不安全");goto out;}if(!strcmp(ph,"preflight")){if(preflight(&c,mn,pn,&updated)){err("preflight 拒绝 EFI 输入或变量");goto out;}rc=result(rf,1,c.matched,0,0)?2:0;}else if(!strcmp(ph,"apply")||!strcmp(ph,"verify")){if(snprintf(c.stage,sizeof(c.stage),"%s/.rootpxe-offline-identities/%s/efi",c.root,c.planid)>=(int)sizeof(c.stage)||stage_ok(&c,mn,pn)||load_vars(&c)||phase_apply_verify(&c,!strcmp(ph,"apply"),&updated)){err("EFI 阶段状态、输入、变量或候选内容不一致");goto out;}rc=result(rf,1,c.nvars,updated,!strcmp(ph,"verify"))?2:0;}else err("phase 必须为 preflight、apply 或 verify");out:free(mn);free(pn);return rc;}
