/* Test-only blocking of the real reader's sched_getcpu call. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <time.h>
static int is_reader;
__attribute__((constructor))static void setup(void){
 char bytes[1024];int fd=open("/proc/self/cmdline",O_RDONLY);if(fd<0)return;
 ssize_t size=read(fd,bytes,sizeof(bytes)-1);close(fd);if(size<=0)return;bytes[size]=0;
 size_t one=strnlen(bytes,(size_t)size)+1;
 if(one>=(size_t)size)return;
 size_t two=one+strnlen(bytes+one,(size_t)size-one)+1;
 if(two<(size_t)size&&!strcmp(bytes,"wtop-hardware-reader")&&!strcmp(bytes+two,"cpuid"))is_reader=1;
}
int sched_getcpu(void){
 const char *control=getenv("WTOP_CPUID_BLOCK_CONTROL"),*marker=getenv("WTOP_CPUID_BLOCK_MARKER");
 if(is_reader&&control&&marker){
  FILE *f=fopen(control,"r");int mode=0;if(f){(void)fscanf(f,"%d",&mode);fclose(f);}
  if(mode){
   f=fopen(marker,"w");if(f){fprintf(f,"%ld\n",(long)getpid());fclose(f);}
   struct timespec wait={10,0};nanosleep(&wait,NULL);
  }
 }
 int (*original)(void)=(int(*)(void))dlsym(RTLD_NEXT,"sched_getcpu");return original?original():-1;
}
