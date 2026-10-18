/* Read-only KMS ABI, independent of installed libdrm/kernel headers.
 * Layouts follow Linux include/uapi/drm/drm_mode.h. No modeset, master,
 * framebuffer-content query or forced connector probe is requested. */
#ifndef WTOP_LINUX_DRM_H
#define WTOP_LINUX_DRM_H
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

typedef struct {
    uint32_t clock;
    uint16_t hdisplay, hsync_start, hsync_end, htotal, hskew;
    uint16_t vdisplay, vsync_start, vsync_end, vtotal, vscan;
    uint32_t vrefresh, flags, type;
    char name[32];
} wtop_drm_modeinfo;
typedef struct {
    uint64_t modes_connector_pointer;
    uint32_t count_connectors, crtc_id, fb_id, x, y, gamma_size, mode_valid;
    wtop_drm_modeinfo mode;
} wtop_drm_crtc;
typedef struct {
    uint32_t encoder_id, encoder_type, crtc_id, possible_crtcs, possible_clones;
} wtop_drm_encoder;
typedef struct {
    uint64_t encoders_ptr, modes_ptr, props_ptr, prop_values_ptr;
    uint32_t count_modes, count_props, count_encoders;
    uint32_t encoder_id, connector_id, connector_type, connector_type_id;
    uint32_t connection, mm_width, mm_height, subpixel, pad;
} wtop_drm_connector;
_Static_assert(sizeof(wtop_drm_modeinfo) == 68, "DRM mode ABI size");
_Static_assert(sizeof(wtop_drm_crtc) == 104, "DRM CRTC ABI size");
_Static_assert(sizeof(wtop_drm_encoder) == 20, "DRM encoder ABI size");
_Static_assert(sizeof(wtop_drm_connector) == 80, "DRM connector ABI size");
_Static_assert(offsetof(wtop_drm_crtc, mode) == 36, "DRM CRTC mode offset");
_Static_assert(offsetof(wtop_drm_connector, connector_id) == 48, "DRM connector ID offset");
#define WTOP_DRM_GETCRTC _IOWR('d', 0xA1, wtop_drm_crtc)
#define WTOP_DRM_GETENCODER _IOWR('d', 0xA6, wtop_drm_encoder)
#define WTOP_DRM_GETCONNECTOR _IOWR('d', 0xA7, wtop_drm_connector)

static int wtop_drm_connector_read(int fd, uint32_t id, wtop_drm_connector *value) {
    wtop_drm_modeinfo temporary;
    memset(&temporary, 0, sizeof(temporary));
    memset(value, 0, sizeof(*value));
    value->connector_id = id;
    /* Zero count_modes can force a probe when the client is DRM master.
     * One valid scratch element requests only cached connector metadata. */
    value->count_modes = 1;
    value->modes_ptr = (uint64_t)(uintptr_t)&temporary;
    if (ioctl(fd, WTOP_DRM_GETCONNECTOR, value)) return -1;
    if (value->connector_id != id || value->connection < 1 || value->connection > 3) {
        errno = ESTALE; return -1;
    }
    return 0;
}
static int wtop_drm_connector_equal(const wtop_drm_connector *a, const wtop_drm_connector *b) {
    return a->connector_id == b->connector_id && a->encoder_id == b->encoder_id
        && a->connector_type == b->connector_type && a->connector_type_id == b->connector_type_id
        && a->connection == b->connection;
}
static int wtop_drm_device(int fd, unsigned device_major, unsigned device_minor) {
    struct stat value;
    if (fstat(fd, &value)) return -1;
    if (!S_ISCHR(value.st_mode) || major(value.st_rdev) != device_major
        || minor(value.st_rdev) != device_minor || device_major != 226) {
        errno = ESTALE; return -1;
    }
    return 0;
}

/* Returns 0 for a stable configured mode, 1 for a stable unconfigured
 * endpoint, -1 with errno for an API failure or a changing endpoint. */
static int wtop_drm_mode_read(int fd, unsigned device_major, unsigned device_minor,
    uint32_t connector_id, wtop_drm_modeinfo *mode) {
    wtop_drm_connector first, last;
    wtop_drm_encoder encoder, encoder_after;
    wtop_drm_crtc crtc, crtc_after;
    int configured = 0;
    memset(mode, 0, sizeof(*mode));
    if (!connector_id) { errno = EINVAL; return -1; }
    if (wtop_drm_device(fd, device_major, device_minor)) return -1;
    if (wtop_drm_connector_read(fd, connector_id, &first)) return -1;
    if (first.encoder_id) {
        memset(&encoder, 0, sizeof(encoder));
        encoder.encoder_id = first.encoder_id;
        if (ioctl(fd, WTOP_DRM_GETENCODER, &encoder)) return -1;
        if (encoder.encoder_id != first.encoder_id) { errno = ESTALE; return -1; }
        if (encoder.crtc_id) {
            memset(&crtc, 0, sizeof(crtc));crtc.crtc_id = encoder.crtc_id;
            if (ioctl(fd, WTOP_DRM_GETCRTC, &crtc)) return -1;
            memset(&crtc_after, 0, sizeof(crtc_after));crtc_after.crtc_id = encoder.crtc_id;
            if (ioctl(fd, WTOP_DRM_GETCRTC, &crtc_after)) return -1;
            /* Page flips can change framebuffer IDs every refresh. They do
             * not change the configured timing and are not compared. */
            if (crtc.crtc_id != encoder.crtc_id || crtc_after.crtc_id != crtc.crtc_id
                || crtc.mode_valid > 1 || crtc.mode_valid != crtc_after.mode_valid
                || memcmp(&crtc.mode, &crtc_after.mode, sizeof(crtc.mode))) {
                errno = ESTALE; return -1;
            }
            configured = crtc.mode_valid != 0;
        }
        memset(&encoder_after, 0, sizeof(encoder_after));encoder_after.encoder_id = first.encoder_id;
        if (ioctl(fd, WTOP_DRM_GETENCODER, &encoder_after)) return -1;
        if (encoder.encoder_id != encoder_after.encoder_id || encoder.crtc_id != encoder_after.crtc_id
            || encoder.encoder_type != encoder_after.encoder_type) { errno = ESTALE; return -1; }
    }
    if (wtop_drm_connector_read(fd, connector_id, &last)) return -1;
    if (!wtop_drm_connector_equal(&first, &last)) { errno = ESTALE; return -1; }
    if (wtop_drm_device(fd, device_major, device_minor)) return -1;
    if (configured) *mode = crtc.mode;
    return configured ? 0 : 1;
}
#endif
