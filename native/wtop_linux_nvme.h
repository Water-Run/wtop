/* Fixed read-only NVMe SMART query. The UAPI layout is independent of the
 * installed kernel headers, including on older build hosts.
 * Linux include/uapi/linux/nvme_ioctl.h; libnvme nvme_get_log(). */
#ifndef WTOP_LINUX_NVME_H
#define WTOP_LINUX_NVME_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

typedef struct {
    uint8_t opcode, flags;
    uint16_t reserved;
    uint32_t nsid, cdw2, cdw3;
    uint64_t metadata, addr;
    uint32_t metadata_len, data_len;
    uint32_t cdw10, cdw11, cdw12, cdw13, cdw14, cdw15;
    uint32_t timeout_ms, result;
} wtop_nvme_admin;

_Static_assert(sizeof(wtop_nvme_admin) == 72, "NVMe admin UAPI size");
_Static_assert(offsetof(wtop_nvme_admin, addr) == 24, "NVMe admin address offset");
_Static_assert(offsetof(wtop_nvme_admin, cdw10) == 40, "NVMe command dword offset");

#define WTOP_NVME_ADMIN _IOWR('N', 0x41, wtop_nvme_admin)
#define WTOP_NVME_DISKSEQ _IOR(0x12, 128, uint64_t)

/* Returns -1 with errno for OS/identity failures, or an unmodified positive
 * NVMe completion status. The caller owns the descriptor throughout. */
static int wtop_nvme_health_read(int fd, unsigned int expected_major,
    unsigned int expected_minor, uint64_t expected_sequence, unsigned char bytes[512]) {
    struct stat metadata;
    uint64_t sequence = 0;
    wtop_nvme_admin command;
    if (fstat(fd, &metadata)) return -1;
    if (!S_ISBLK(metadata.st_mode) || major(metadata.st_rdev) != expected_major
        || minor(metadata.st_rdev) != expected_minor || !expected_sequence) {
        errno = ESTALE; return -1;
    }
    if (ioctl(fd, WTOP_NVME_DISKSEQ, &sequence)) return -1;
    if (sequence != expected_sequence) { errno = ESTALE; return -1; }
    memset(&command, 0, sizeof(command));
    memset(bytes, 0, 512);
    command.opcode = 0x02; /* Get Log Page, SMART/Health only. */
    command.nsid = UINT32_MAX; /* Controller-wide health, not namespace use. */
    command.addr = (uint64_t)(uintptr_t)bytes;
    command.data_len = 512;
    command.cdw10 = (127u << 16) | (1u << 15) | 0x02; /* NUMDL, retain events, LID. */
    command.timeout_ms = 1000;
    int status = ioctl(fd, WTOP_NVME_ADMIN, &command);
    if (status != 0) return status;
    if (ioctl(fd, WTOP_NVME_DISKSEQ, &sequence)) return -1;
    if (sequence != expected_sequence) { errno = ESTALE; return -1; }
    return 0;
}
#endif
