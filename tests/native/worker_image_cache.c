#define _GNU_SOURCE
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define GPU_VENDOR_COUNT 3
struct gpu_job { unsigned vendor; int shared_image; };
static atomic_uint creations;
static int seals_mode = 1, duplicate_failure, use_barrier, seals_query_failure;
static pthread_barrier_t barrier;

static int create_image(unsigned source, char path[PATH_MAX]) {
    path[0] = 0;
    atomic_fetch_add(&creations, 1);
    int fd;
    char temporary[] = "/tmp/wtop-image-fixture-XXXXXX";
    if (seals_mode == 2) fd = mkstemp(temporary);
    else fd = (int)syscall(SYS_memfd_create, "wtop-image-fixture", 3u);
    assert(fd >= 0);
    const char *text = source < GPU_VENDOR_COUNT ? "GPU image" : "hardware image";
    assert(write(fd, text, strlen(text)) == (ssize_t)strlen(text));
    if (seals_mode == 1)
        assert(fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK|F_SEAL_SEAL) == 0);
    char name[64];
    snprintf(name, sizeof(name), "/proc/self/fd/%d", fd);
    int reader = open(name, O_RDONLY|O_CLOEXEC);
    assert(reader >= 0);
    close(fd);
    if (seals_mode == 2) assert(unlink(temporary) == 0);
    int result = fcntl(reader, F_DUPFD_CLOEXEC, 10);
    close(reader); assert(result >= 0);
    if (use_barrier) (void)pthread_barrier_wait(&barrier);
    return result;
}

static int fixture_fcntl(int fd, int command, ...) {
    if (command == F_DUPFD_CLOEXEC) {
        if (duplicate_failure) { errno = EMFILE; return -1; }
        return fcntl(fd, command, 10);
    }
    assert(command == F_GET_SEALS);
    if (seals_query_failure) { errno = EPERM; return -1; }
    return fcntl(fd, command);
}
#ifdef WTOP_TEST_NO_SEALS
#undef F_GET_SEALS
#endif
#define fcntl fixture_fcntl
#include "wtop_worker_image_cache.h"
#undef fcntl

static unsigned descriptors(void) {
    DIR *dir = opendir("/proc/self/fd"); assert(dir);
    unsigned n = 0; struct dirent *entry;
    while ((entry = readdir(dir))) if (entry->d_name[0] != '.') ++n;
    assert(closedir(dir) == 0); return n;
}
static int same_file(int a, int b) {
    struct stat x,y;assert(!fstat(a,&x)&&!fstat(b,&y));
    return x.st_dev==y.st_dev && x.st_ino==y.st_ino;
}
static int acquire(struct gpu_job *job) {
    char path[PATH_MAX];int fd=acquire_image(job,path);
    assert(fd>=0 && !path[0] && (fcntl(fd,F_GETFL)&O_ACCMODE)==O_RDONLY);
    assert(fcntl(fd,F_GETFD)&FD_CLOEXEC);return fd;
}
static void finish(struct gpu_job *job,int fd) { close(fd);release_image(job); }
#ifndef WTOP_TEST_NO_SEALS
struct threaded { struct gpu_job job; int fd; };
static void *start(void *opaque) { struct threaded *t=opaque;t->fd=acquire(&t->job);return NULL; }
#endif

int main(void) {
    unsigned before=descriptors();
    struct gpu_job a={.vendor=3},b={.vendor=4};
    int one=acquire(&a),two=acquire(&b);
#ifdef WTOP_TEST_NO_SEALS
    assert(!a.shared_image && !b.shared_image && !same_file(one,two));
    finish(&a,one);finish(&b,two);assert(descriptors()==before);
    puts("image cache fixture: no-seals-header fallback, readonly descriptors and exact cleanup passed");
    return 0;
#else
    struct gpu_job g={.vendor=0};
    assert(a.shared_image && b.shared_image && same_file(one,two));
    assert(atomic_load(&creations)==1);
    int gpu=acquire(&g);assert(!same_file(one,gpu));
    char proc[64];snprintf(proc,sizeof(proc),"/proc/self/fd/%d",one);
    int writer=open(proc,O_RDWR|O_CLOEXEC);assert(writer>=0);
    errno=0;assert(write(writer,"x",1)<0 && errno==EPERM);
    errno=0;assert(ftruncate(writer,0)<0 && errno==EPERM);
    close(writer);
    finish(&a,one);assert(b.shared_image && cached_identity(&image_cache[1]));
    finish(&b,two);finish(&g,gpu);assert(descriptors()==before);

    for(int mode=0;mode<=2;mode+=2) {
        seals_mode=mode;a=(struct gpu_job){.vendor=3};b=(struct gpu_job){.vendor=4};
        one=acquire(&a);two=acquire(&b);
        assert(!a.shared_image && !b.shared_image && !same_file(one,two));
        finish(&a,one);finish(&b,two);assert(descriptors()==before);
    }
    seals_mode=1;
    duplicate_failure=1;a=(struct gpu_job){.vendor=3};
    one=acquire(&a);assert(!a.shared_image);finish(&a,one);assert(descriptors()==before);
    duplicate_failure=0;
    a=(struct gpu_job){.vendor=3};one=acquire(&a);
    duplicate_failure=1;b=(struct gpu_job){.vendor=4};two=acquire(&b);
    assert(a.shared_image && !b.shared_image && !same_file(one,two));
    finish(&a,one);finish(&b,two);duplicate_failure=0;assert(descriptors()==before);

    a=(struct gpu_job){.vendor=3};one=acquire(&a);assert(a.shared_image);
    seals_query_failure=1;finish(&a,one);seals_query_failure=0;
    assert(descriptors()==before && "seals-query failure must not leak the owned holder on final release");

    struct threaded threads[8]={0};pthread_t ids[8];
    assert(!pthread_barrier_init(&barrier,NULL,8));use_barrier=1;
    unsigned count=atomic_load(&creations);
    for(unsigned i=0;i<8;++i){threads[i].job.vendor=3+i;assert(!pthread_create(&ids[i],NULL,start,&threads[i]));}
    for(unsigned i=0;i<8;++i)assert(!pthread_join(ids[i],NULL));
    assert(atomic_load(&creations)==count+8);
    for(unsigned i=0;i<8;++i){assert(threads[i].job.shared_image && same_file(threads[0].fd,threads[i].fd));}
    use_barrier=0;pthread_barrier_destroy(&barrier);
    for(unsigned i=0;i<8;++i)finish(&threads[i].job,threads[i].fd);
    assert(descriptors()==before);

    a=(struct gpu_job){.vendor=3};one=acquire(&a);
    int borrowed=image_cache[1].fd;
    assert(close(borrowed)==0);
    char path[PATH_MAX];int foreign=create_image(0,path);
    assert(dup2(foreign,borrowed)==borrowed);
    b=(struct gpu_job){.vendor=4};two=acquire(&b);assert(!b.shared_image);
    finish(&a,one);assert(fcntl(borrowed,F_GETFD)>=0);
    finish(&b,two);close(borrowed);close(foreign);
    assert(descriptors()==before);
    puts("image cache fixture: readonly seals, two image classes, exact refcounts, unsealed/tmpfile fallback, duplicate failures, seal-query failure cleanup, eight racing publishers and replaced descriptor ownership passed");
    return 0;
#endif
}
