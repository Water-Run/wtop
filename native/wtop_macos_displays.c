/* Read-only WindowServer display state. OS displays can be virtual; no EDID,
 * physical dimensions, serial values or GPU ancestry are inferred here. */
#include <lua.h>
#include <lauxlib.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ColorSync/ColorSyncDevice.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "wtop_macos.h"

#define DISPLAY_LIMIT 128
struct display_mode {
    size_t width, height, pixel_width, pixel_height;
    double refresh;
    int32_t identifier;
    uint32_t flags;
    int present, valid;
};
struct display_state {
    unsigned char uuid[16];
    uint32_t vendor, model;
    int identity, online, active, asleep, builtin, main;
    struct display_mode mode;
};
struct display_record {
    struct display_state value;
    uint64_t observed;
    int verified, duplicate;
};

static uint64_t display_now_ns(void) {
    /* Use the same epoch as process frames and snapshot timestamps. Mach
     * absolute time can have a different suspend history from CLOCK_MONOTONIC. */
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value)) return 0;
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static void capture_display(CGDirectDisplayID display, struct display_state *state) {
    memset(state, 0, sizeof(*state));
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
    if (uuid) {
        CFUUIDBytes bytes = CFUUIDGetUUIDBytes(uuid);
        memcpy(state->uuid, &bytes, sizeof(state->uuid));
        unsigned char nonzero = 0;
        for (unsigned i = 0; i < sizeof(state->uuid); ++i) nonzero |= state->uuid[i];
        state->identity = nonzero != 0;
        CFRelease(uuid);
    }
    state->online = CGDisplayIsOnline(display) != 0;
    state->active = CGDisplayIsActive(display) != 0;
    state->asleep = CGDisplayIsAsleep(display) != 0;
    state->builtin = CGDisplayIsBuiltin(display) != 0;
    state->main = CGDisplayIsMain(display) != 0;
    state->vendor = CGDisplayVendorNumber(display);
    state->model = CGDisplayModelNumber(display);
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (mode) {
        struct display_mode *m = &state->mode;
        m->present = 1;
        m->width = CGDisplayModeGetWidth(mode);
        m->height = CGDisplayModeGetHeight(mode);
        m->pixel_width = CGDisplayModeGetPixelWidth(mode);
        m->pixel_height = CGDisplayModeGetPixelHeight(mode);
        m->refresh = CGDisplayModeGetRefreshRate(mode);
        m->identifier = CGDisplayModeGetIODisplayModeID(mode);
        m->flags = CGDisplayModeGetIOFlags(mode);
        m->valid = m->width > 0 && m->width <= INT32_MAX
            && m->height > 0 && m->height <= INT32_MAX
            && m->pixel_width > 0 && m->pixel_width <= INT32_MAX
            && m->pixel_height > 0 && m->pixel_height <= INT32_MAX
            && isfinite(m->refresh) && m->refresh >= 0 && m->refresh <= 10000;
        CGDisplayModeRelease(mode);
    }
}

static void text_field(lua_State *L, const char *name, const char *value) {
    lua_pushstring(L, value); lua_setfield(L, -2, name);
}
static void integer_field(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value); lua_setfield(L, -2, name);
}
static void boolean_field(lua_State *L, const char *name, int value) {
    lua_pushboolean(L, value); lua_setfield(L, -2, name);
}

int wtop_collect_displays(lua_State *L) {
    /* Lua owns the only output buffer before acquiring any CF objects. Every
     * UUID/mode is released before Lua allocation can fail or longjmp. */
    struct display_record *records = lua_newuserdatauv(L, DISPLAY_LIMIT * sizeof(*records), 0);
    memset(records, 0, DISPLAY_LIMIT * sizeof(*records));
    CGDirectDisplayID first[DISPLAY_LIMIT + 1] = {0}, last[DISPLAY_LIMIT + 1] = {0};
    uint32_t count = 0, final_count = 0;
    CGError error = CGGetOnlineDisplayList(DISPLAY_LIMIT + 1, first, &count);
    if (count > DISPLAY_LIMIT + 1) count = DISPLAY_LIMIT + 1;
    unsigned retained = count > DISPLAY_LIMIT ? DISPLAY_LIMIT : count;
    int partial = 0, inventory_complete = 1;
    if (error == kCGErrorSuccess) {
        for (unsigned i = 0; i < retained; ++i) capture_display(first[i], &records[i].value);
        for (unsigned i = 0; i < retained; ++i) {
            struct display_state check;
            capture_display(first[i], &check);
            records[i].verified = first[i] && check.online && check.identity
                && !memcmp(&check, &records[i].value, sizeof(check));
            records[i].observed = display_now_ns();
            for (unsigned j = 0; j < retained; ++j) {
                if (i != j && (first[i] == first[j] || (check.identity && records[j].value.identity
                    && !memcmp(check.uuid, records[j].value.uuid, sizeof(check.uuid))))) records[i].duplicate = 1;
            }
        }
        CGError final_error = CGGetOnlineDisplayList(DISPLAY_LIMIT + 1, last, &final_count);
        if (final_error != kCGErrorSuccess) final_count = 0;
        if (final_count > DISPLAY_LIMIT + 1) final_count = DISPLAY_LIMIT + 1;
        for (unsigned i = 0; i < retained; ++i) {
            unsigned occurrences = 0;
            for (unsigned j = 0; j < final_count; ++j) if (last[j] == first[i]) ++occurrences;
            if (final_error != kCGErrorSuccess || occurrences != 1) records[i].verified = 0;
            if (records[i].duplicate || !records[i].verified || !records[i].value.mode.valid) partial = 1;
        }
        if (final_error != kCGErrorSuccess || count != final_count) partial = 1, inventory_complete = 0;
        /* Equal-sized enumeration replacement is still an incomplete batch. */
        for (unsigned j = 0; j < final_count; ++j) {
            unsigned occurrences = 0;
            for (unsigned i = 0; i < count; ++i) if (first[i] == last[j]) ++occurrences;
            if (occurrences != 1) partial = 1, inventory_complete = 0;
        }
    } else retained = 0;

    lua_createtable(L, 0, 8);
    text_field(L, "backend", "coregraphics");
    text_field(L, "status", error == kCGErrorSuccess ? (count ? "ok" : partial ? "error" : "unavailable") : "error");
    integer_field(L, "cg_error", error);
    integer_field(L, "total", count);
    boolean_field(L, "truncated", count > DISPLAY_LIMIT);
    boolean_field(L, "total_is_lower_bound", count > DISPLAY_LIMIT || !inventory_complete);
    text_field(L, "quality", partial ? "partial" : "fresh");
    lua_createtable(L, (int)retained, 0);
    for (unsigned i = 0; i < retained; ++i) {
        struct display_record *r = &records[i];
        struct display_state *s = &r->value;
        int valid = r->verified && !r->duplicate;
        char id[32]; snprintf(id, sizeof(id), "monitor%u", i);
        lua_createtable(L, 0, 16);
        text_field(L, "id", id);
        boolean_field(L, "_identity_verified", valid);
        integer_field(L, "observed_at_ns", (lua_Integer)r->observed);
        text_field(L, "quality", valid ? (s->mode.valid ? "fresh" : "partial") : "gap");
        if (valid) {
            char key[33];
            for (unsigned j = 0; j < sizeof(s->uuid); ++j) snprintf(key + 2 * j, 3, "%02x", s->uuid[j]);
            text_field(L, "_display_identity", key);
            boolean_field(L, "online", s->online);
            boolean_field(L, "active", s->active);
            boolean_field(L, "asleep", s->asleep);
            boolean_field(L, "builtin", s->builtin);
            boolean_field(L, "main", s->main);
            if (s->vendor) integer_field(L, "vendor_number", s->vendor);
            if (s->model) integer_field(L, "model_number", s->model);
            text_field(L, "current_mode_status", s->mode.valid ? "ok" : s->mode.present ? "error" : "unavailable");
            if (s->mode.valid) {
                lua_createtable(L, 0, 6);
                integer_field(L, "width_points", (lua_Integer)s->mode.width);
                integer_field(L, "height_points", (lua_Integer)s->mode.height);
                integer_field(L, "pixel_width", (lua_Integer)s->mode.pixel_width);
                integer_field(L, "pixel_height", (lua_Integer)s->mode.pixel_height);
                /* Zero is unspecified (including variable-refresh displays),
                 * not a measured zero-Hz panel. */
                if (s->mode.refresh > 0) {
                    lua_pushnumber(L, s->mode.refresh); lua_setfield(L, -2, "refresh_hz");
                }
                lua_setfield(L, -2, "current_mode");
            } else text_field(L, "reason", "display_current_mode_unavailable");
        } else text_field(L, "reason", s->identity ? "display_changed_during_read" : "display_identity_unavailable");
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "devices");
    return 1;
}
