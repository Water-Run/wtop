#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

static int stage, scenario, commands;
static int fake_stat(int fd, struct stat *st) {
    assert(fd == 9);
    memset(st, 0, sizeof(*st));
    st->st_mode = scenario == 1 ? S_IFREG : S_IFBLK;
    st->st_rdev = makedev(259, scenario == 2 ? 1 : 0);
    if (scenario == 3) { errno = EIO; return -1; }
    return 0;
}
static int fake_ioctl(int fd, unsigned long request, ...);
#define fstat fake_stat
#define ioctl fake_ioctl
#include "wtop_linux_nvme.h"
#undef fstat
#undef ioctl

static int fake_ioctl(int fd, unsigned long request, ...) {
    va_list args;
    assert(fd == 9);
    va_start(args, request);
    void *opaque = va_arg(args, void *);
    va_end(args);
    if (request == WTOP_NVME_DISKSEQ) {
        if (scenario == 4) { errno = ENOTTY; return -1; }
        *(uint64_t *)opaque = scenario == 5 || (scenario == 6 && stage > 0) ? 8 : 7;
        ++stage;
        return 0;
    }
    assert(request == WTOP_NVME_ADMIN);
    ++commands;
    wtop_nvme_admin *cmd = opaque;
    assert(cmd->opcode == 2 && cmd->nsid == UINT32_MAX && cmd->flags == 0);
    assert(cmd->cdw10 == ((127u << 16) | (1u << 15) | 2));
    assert(cmd->data_len == 512 && cmd->metadata_len == 0 && cmd->metadata == 0);
    assert(cmd->cdw2 == 0 && cmd->cdw3 == 0 && cmd->cdw11 == 0);
    assert(cmd->cdw12 == 0 && cmd->cdw13 == 0 && cmd->cdw14 == 0 && cmd->cdw15 == 0);
    assert(cmd->timeout_ms == 1000 && cmd->result == 0);
    if (scenario == 7) { errno = EACCES; return -1; }
    if (scenario == 8) return 0x102;
    memset((void *)(uintptr_t)cmd->addr, 0x42, 512);
    return 0;
}

int main(void) {
    unsigned char bytes[512];
    for (scenario = 0; scenario <= 8; ++scenario) {
        stage = commands = 0;
        int rc = wtop_nvme_health_read(9, 259, 0, 7, bytes);
        if (scenario == 0) assert(rc == 0 && bytes[0] == 0x42 && bytes[511] == 0x42 && stage == 2);
        else if (scenario == 8) assert(rc == 0x102 && commands == 1);
        else assert(rc == -1);
        if (scenario >= 1 && scenario <= 5) assert(commands == 0);
        if (scenario == 6) assert(errno == ESTALE && commands == 1);
        if (scenario == 7) assert(errno == EACCES && commands == 1);
    }
    stage = commands = scenario = 0;
    assert(wtop_nvme_health_read(9, 259, 0, 0, bytes) == -1 && commands == 0);
    return 0;
}
