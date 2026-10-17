#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include "wtop_linux_nvme.h"

static int original_open(const char *path, int flags, mode_t mode) {
    static int (*fn)(const char *, int, ...);
    if (!fn) *(void **)(&fn) = dlsym(RTLD_NEXT, "open");
    return fn(path, flags, mode);
}

static int selected(int fd) {
    char path[64], target[4096];
    const char *fixture = getenv("WTOP_NVME_FIXTURE_DEVICE");
    if (!fixture) return 0;
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(path, target, sizeof(target) - 1);
    if (n < 0) return 0;
    target[n] = '\0';
    return strcmp(target, fixture) == 0;
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = va_arg(args, mode_t); va_end(args); }
    const char *fixture = getenv("WTOP_NVME_FIXTURE_DEVICE");
    if (fixture && strcmp(path, "/dev/nvme0n1") == 0) {
        if ((flags & O_ACCMODE) != O_RDONLY || !(flags & O_NOFOLLOW)) _Exit(91);
        return original_open(fixture, flags, mode);
    }
    return original_open(path, flags, mode);
}

int fstat(int fd, struct stat *st) {
    static int (*fn)(int, struct stat *);
    if (!fn) *(void **)(&fn) = dlsym(RTLD_NEXT, "fstat");
    int result = fn(fd, st);
    if (!result && selected(fd)) { st->st_mode = S_IFBLK | 0600; st->st_rdev = makedev(259, 0); }
    return result;
}

int ioctl(int fd, unsigned long request, ...) {
    va_list args;
    va_start(args, request);
    void *arg = va_arg(args, void *);
    va_end(args);
    if (!selected(fd)) {
        static int (*fn)(int, unsigned long, ...);
        if (!fn) *(void **)(&fn) = dlsym(RTLD_NEXT, "ioctl");
        return fn(fd, request, arg);
    }
    if (request == WTOP_NVME_DISKSEQ) { *(uint64_t *)arg = 7; return 0; }
    if (request != WTOP_NVME_ADMIN) _Exit(92);
    wtop_nvme_admin *cmd = arg;
    if (cmd->opcode != 2 || cmd->nsid != UINT32_MAX || cmd->data_len != 512
        || cmd->cdw10 != ((127u << 16) | (1u << 15) | 2)) _Exit(93);
    const char *entered = getenv("WTOP_NVME_FIXTURE_ENTERED");
    int mark = entered ? original_open(entered, O_WRONLY | O_CREAT | O_TRUNC, 0600) : -1;
    if (mark >= 0) { char pid[32]; int n = snprintf(pid, sizeof(pid), "%ld\n", (long)getpid());
        if (write(mark, pid, (size_t)n) != n) _Exit(94);
        close(mark); }
    const char *control = getenv("WTOP_NVME_FIXTURE_CONTROL");
    if (control) {
        int input = original_open(control, O_RDONLY, 0);
        char value = 0;
        if (input >= 0) { if (read(input, &value, 1) != 1) value = 0; close(input); }
        if (value == '1') for (;;) pause();
    }
    unsigned char *data = (unsigned char *)(uintptr_t)cmd->addr;
    memset(data, 0, 512);
    data[1] = 0x28; data[2] = 1; data[3] = 100; data[4] = 10; data[5] = 1;
    data[32] = 42;
    return 0;
}

/* The header's helper is exercised in the ordinary fixture executable; this
 * DSO needs it referenced as well under -Werror without issuing real I/O. */
__attribute__((unused)) static void reference_helper(void) { (void)wtop_nvme_health_read; }
