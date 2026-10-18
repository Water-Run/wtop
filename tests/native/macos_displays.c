/* Exercise the production collector with deterministic CoreGraphics snapshots. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ColorSync/ColorSyncDevice.h>
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { EMPTY = 1, FIRST_FAIL = 2, LAST_FAIL = 4, REORDER = 8,
    DISAPPEAR = 16, REPLACED = 32, MODE_CHANGED = 64, OFFLINE = 128,
    DUPLICATE_ID = 256, DUPLICATE_UUID = 512, NO_UUID = 1024, NO_MODE = 2048,
    BAD_SIZE = 4096, BAD_RATE = 8192, ZERO_RATE = 16384, RETINA = 32768,
    CAPPED = 65536, NEW_DISPLAY = 131072, EMPTY_CHANGED = 262144,
    MODE_ID_CHANGED = 524288, STATE_CHANGED = 1048576, NO_CONNECTION = 2097152,
    ADDED_DISPLAY = 4194304 };
static unsigned scenario, enumerations, captures, references;
static int fail_allocation, oom_enabled;
static CGError fixture_list(uint32_t capacity, CGDirectDisplayID *ids, uint32_t *count) {
    assert(capacity == 129 && ids); ++enumerations;
    if (enumerations == 2 && oom_enabled) fail_allocation = 1;
    *count = 0;
    if (scenario & NO_CONNECTION) return kCGErrorInvalidConnection;
    if ((scenario & FIRST_FAIL) || ((scenario & LAST_FAIL) && enumerations == 2)) return kCGErrorFailure;
    if ((scenario & EMPTY) || ((scenario & EMPTY_CHANGED) && enumerations == 1)) return kCGErrorSuccess;
    *count = scenario & CAPPED ? 129 : 2;
    if ((scenario & ADDED_DISPLAY) && enumerations == 2) *count = 3;
    if ((scenario & DISAPPEAR) && enumerations == 2) *count = 1;
    for (unsigned i = 0; i < *count; ++i) ids[i] = i + 10;
    if ((scenario & REORDER) && enumerations == 2) { ids[0] = 11; ids[1] = 10; }
    if (scenario & DUPLICATE_ID) ids[1] = 10;
    if ((scenario & NEW_DISPLAY) && enumerations == 2) ids[1] = 30;
    return kCGErrorSuccess;
}
static unsigned phase(CGDirectDisplayID id) { return id == 10 && captures > (scenario & CAPPED ? 128u : 2u); }
static CFUUIDRef fixture_uuid(uint32_t id) {
    ++captures;
    if ((scenario & NO_UUID) && id == 10) return NULL;
    if ((scenario & DUPLICATE_UUID) && id == 11) id = 10;
    if ((scenario & REPLACED) && phase(id)) id += 1000;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, (CFUUIDBytes){(unsigned char)id,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15});
    assert(uuid); ++references; return uuid;
}
static void fixture_release(CFTypeRef value) { assert(value && references); --references; CFRelease(value); }
static CGDisplayModeRef fixture_mode(CGDirectDisplayID id) {
    if ((scenario & NO_MODE) && id == 10) return NULL;
    ++references; return (CGDisplayModeRef)(uintptr_t)id;
}
static void fixture_mode_release(CGDisplayModeRef mode) { assert(mode && references); --references; }
static boolean_t fixture_online(CGDirectDisplayID id) { return !((scenario & OFFLINE) && id == 10 && phase(id)); }
static boolean_t fixture_active(CGDirectDisplayID id) { return !((scenario & STATE_CHANGED) && id == 10 && phase(id)); }
static boolean_t fixture_false(CGDirectDisplayID id) { (void)id; return 0; }
static boolean_t fixture_main(CGDirectDisplayID id) { return id == 10; }
static uint32_t fixture_vendor(CGDirectDisplayID id) { (void)id; return 1970170734; }
static uint32_t fixture_model(CGDirectDisplayID id) { (void)id; return 1986622068; }
static size_t fixture_width(CGDisplayModeRef mode) {
    unsigned id = (unsigned)(uintptr_t)mode;
    if ((scenario & BAD_SIZE) && id == 10) return SIZE_MAX;
    return (scenario & MODE_CHANGED) && phase(id) ? 1280 : 1920;
}
static size_t fixture_height(CGDisplayModeRef mode) { (void)mode; return 1080; }
static size_t fixture_pixel_width(CGDisplayModeRef mode) { return fixture_width(mode) * (scenario & RETINA ? 2 : 1); }
static size_t fixture_pixel_height(CGDisplayModeRef mode) { return fixture_height(mode) * (scenario & RETINA ? 2 : 1); }
static double fixture_rate(CGDisplayModeRef mode) {
    if ((unsigned)(uintptr_t)mode == 10) {
        if (scenario & ZERO_RATE) return 0;
        if (scenario & BAD_RATE) return NAN;
    }
    return 59.94;
}
static int32_t fixture_mode_id(CGDisplayModeRef mode) {
    unsigned id = (unsigned)(uintptr_t)mode;
    return (int32_t)id + ((scenario & MODE_ID_CHANGED) && phase(id) ? 10 : 0);
}
static uint32_t fixture_mode_flags(CGDisplayModeRef mode) { (void)mode; return 0; }
#define CGGetOnlineDisplayList fixture_list
#define CGDisplayCreateUUIDFromDisplayID fixture_uuid
#define CFRelease fixture_release
#define CGDisplayCopyDisplayMode fixture_mode
#define CGDisplayModeRelease fixture_mode_release
#define CGDisplayIsOnline fixture_online
#define CGDisplayIsActive fixture_active
#define CGDisplayIsAsleep fixture_false
#define CGDisplayIsBuiltin fixture_false
#define CGDisplayIsMain fixture_main
#define CGDisplayVendorNumber fixture_vendor
#define CGDisplayModelNumber fixture_model
#define CGDisplayModeGetWidth fixture_width
#define CGDisplayModeGetHeight fixture_height
#define CGDisplayModeGetPixelWidth fixture_pixel_width
#define CGDisplayModeGetPixelHeight fixture_pixel_height
#define CGDisplayModeGetRefreshRate fixture_rate
#define CGDisplayModeGetIODisplayModeID fixture_mode_id
#define CGDisplayModeGetIOFlags fixture_mode_flags
#include "../../native/wtop_macos_displays.c"

static void check(lua_State *L, unsigned flags, const char *script) {
    scenario = flags; enumerations = captures = references = 0;
    lua_pushcfunction(L, wtop_collect_displays);
    int status = lua_pcall(L, 0, 1, 0);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    assert(status == LUA_OK && references == 0);
    lua_setglobal(L, "data");
    status = luaL_dostring(L, script);
    if (status != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    assert(status == LUA_OK);
}
struct allocator { lua_Alloc original; void *context; };
static void *failing_allocator(void *context, void *pointer, size_t old, size_t size) {
    struct allocator *a = context;
    if (size && fail_allocation) { assert(references == 0); return NULL; }
    return a->original(a->context, pointer, old, size);
}
int main(void) {
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L);
    const char *healthy = "assert(data.status=='ok' and data.backend=='coregraphics' and data.quality=='fresh' and #data.devices==2); "
        "local r=data.devices[1];assert(r._identity_verified and r.online and r.active and not r.builtin and r.main); "
        "assert(r.current_mode.width_points==1920 and r.current_mode.pixel_width==1920 and r.current_mode.refresh_hz==59.94); "
        "assert(r.vendor_number==1970170734 and r.model_number==1986622068 and #r._display_identity==32); "
        "assert(r.edid==nil and r.width_mm==nil and r.serial==nil)";
    check(L, 0, healthy); check(L, REORDER, healthy);
    check(L, EMPTY, "assert(data.status=='unavailable' and data.total==0 and #data.devices==0)");
    check(L, FIRST_FAIL, "assert(data.status=='error' and #data.devices==0)");
    check(L, NO_CONNECTION, "assert(data.status=='error' and data.cg_error==1002 and #data.devices==0)");
    check(L, EMPTY_CHANGED, "assert(data.status=='error' and #data.devices==0)");
    for (unsigned flag = LAST_FAIL; flag <= NO_UUID; flag <<= 1) {
        if (flag == REORDER || flag == DISAPPEAR) continue;
        check(L, flag, "local r=data.devices[1];assert(data.quality=='partial' and r.quality=='gap' and r.current_mode==nil and r._display_identity==nil)");
    }
    check(L, DISAPPEAR, "assert(data.devices[1].quality=='fresh' and data.devices[2].quality=='gap' and data.quality=='partial')");
    check(L, NEW_DISPLAY, "assert(data.devices[1].quality=='fresh' and data.devices[2].quality=='gap' and data.quality=='partial')");
    check(L, ADDED_DISPLAY, "assert(data.devices[1].quality=='fresh' and data.devices[2].quality=='fresh' and data.quality=='partial' and data.total_is_lower_bound)");
    for (unsigned flag = MODE_ID_CHANGED; flag <= STATE_CHANGED; flag <<= 1)
        check(L, flag, "assert(data.devices[1].quality=='gap' and data.devices[1].current_mode==nil)");
    for (unsigned flag = NO_MODE; flag <= BAD_RATE; flag <<= 1)
        check(L, flag, "local r=data.devices[1];assert(r.quality=='partial' and r.current_mode==nil and r._identity_verified and r.online)");
    check(L, ZERO_RATE, "assert(data.devices[1].quality=='fresh' and data.devices[1].current_mode.refresh_hz==nil)");
    check(L, RETINA, "local m=data.devices[1].current_mode;assert(m.width_points==1920 and m.pixel_width==3840 and m.pixel_height==2160)");
    check(L, CAPPED, "assert(data.total==129 and #data.devices==128 and data.truncated and data.total_is_lower_bound and data.quality=='fresh')");
    struct allocator a; a.original = lua_getallocf(L, &a.context); lua_setallocf(L, failing_allocator, &a);
    scenario = enumerations = captures = references = 0;
    lua_pushcfunction(L, wtop_collect_displays); oom_enabled = 1;
    int status = lua_pcall(L, 0, 1, 0);
    assert(status == LUA_ERRMEM && references == 0);
    fail_allocation = oom_enabled = 0; lua_setallocf(L, a.original, a.context); lua_pop(L, 1);
    lua_close(L);
    puts("ok: macOS display state/modes, reorder, replacement, mode/state race, absence, caps, nominal/unspecified Hz, Retina, errors and CF release before Lua OOM");
    return 0;
}
