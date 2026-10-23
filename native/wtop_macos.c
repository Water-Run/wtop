/* macOS backend. Uses Mach, libproc, sysctl and BSD interfaces. */
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <lua.h>
#include <lauxlib.h>
#include "wtop_edid_license.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IOStorageDeviceCharacteristics.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>

#include <errno.h>
#include "wtop_fs_errors.h"
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <locale.h>
#include <mach/mach.h>
#include <mach/host_info.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_mib.h>
#include <net/route.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include "wtop_terminal_signal.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

#include "wtop_macos.h"
#include "wtop_macos_cpu.h"
#include "wtop_build.h"

#define MAX_PROCESS_COUNT 8192

static struct termios saved_terminal;
static int terminal_active = 0;
static int cleanup_registered = 0;

static struct sigaction previous_winch, previous_int, previous_term, previous_hup;
static locale_t width_locale = (locale_t)0;

static void integer_field(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, name);
}

static void number_field(lua_State *L, const char *name, lua_Number value) {
    lua_pushnumber(L, value);
    lua_setfield(L, -2, name);
}

static void string_field(lua_State *L, const char *name, const char *value) {
    lua_pushstring(L, value);
    lua_setfield(L, -2, name);
}

static int push_errno(lua_State *L, const char *operation) {
    int code = errno;
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", operation, strerror(code));
    lua_pushinteger(L, code);
    return 3;
}

static void restore_terminal(void) {
    if (!terminal_active) return;
    (void)tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_terminal);
    (void)sigaction(SIGWINCH, &previous_winch, NULL);
    (void)sigaction(SIGINT, &previous_int, NULL);
    (void)sigaction(SIGTERM, &previous_term, NULL);
    (void)sigaction(SIGHUP, &previous_hup, NULL);
    terminal_active = 0;
}

static void terminal_signal(int number) {
    wtop_terminal_signal_notify(number);
}

static int l_terminal_start(lua_State *L) {
    struct termios raw;
    struct sigaction action;
    if (terminal_active) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        lua_pushnil(L);
        lua_pushliteral(L, "stdin and stdout must be TTYs");
        return 2;
    }
    if (tcgetattr(STDIN_FILENO, &saved_terminal) != 0)
        return push_errno(L, "tcgetattr");
    raw = saved_terminal;
    raw.c_iflag &= (tcflag_t)~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= (tcflag_t)~OPOST;
    raw.c_cflag |= CS8;
    raw.c_lflag &= (tcflag_t)~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0)
        return push_errno(L, "tcsetattr");
    wtop_terminal_signal_reset(0);
    memset(&action, 0, sizeof(action));
    action.sa_handler = terminal_signal;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGWINCH, &action, &previous_winch) != 0) goto failed;
    if (sigaction(SIGINT, &action, &previous_int) != 0) {
        (void)sigaction(SIGWINCH, &previous_winch, NULL);
        goto failed;
    }
    if (sigaction(SIGTERM, &action, &previous_term) != 0) {
        (void)sigaction(SIGINT, &previous_int, NULL);
        (void)sigaction(SIGWINCH, &previous_winch, NULL);
        goto failed;
    }
    if (sigaction(SIGHUP, &action, &previous_hup) != 0) {
        (void)sigaction(SIGTERM, &previous_term, NULL);
        (void)sigaction(SIGINT, &previous_int, NULL);
        (void)sigaction(SIGWINCH, &previous_winch, NULL);
        goto failed;
    }
    terminal_active = 1;
    wtop_terminal_signal_notify(SIGWINCH);
    if (!cleanup_registered) {
        if (atexit(restore_terminal) != 0) {
            restore_terminal();
            lua_pushnil(L);
            lua_pushliteral(L, "atexit registration failed");
            return 2;
        }
        cleanup_registered = 1;
    }
    lua_pushboolean(L, 1);
    return 1;
failed:
    (void)tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_terminal);
    return push_errno(L, "sigaction");
}

static int l_terminal_stop(lua_State *L) {
    restore_terminal();
    lua_pushboolean(L, 1);
    return 1;
}

static int l_terminal_size(lua_State *L) {
    struct winsize size;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0)
        return push_errno(L, "ioctl(TIOCGWINSZ)");
    lua_pushinteger(L, size.ws_col > 0 ? size.ws_col : 80);
    lua_pushinteger(L, size.ws_row > 0 ? size.ws_row : 24);
    return 2;
}

static int l_poll(lua_State *L) {
    lua_Integer timeout = luaL_optinteger(L, 1, -1);
    struct pollfd descriptor = {STDIN_FILENO, POLLIN | POLLHUP, 0};
    char buffer[4096];
    ssize_t count = 0;
    int ready;
    luaL_argcheck(L, timeout >= -1 && timeout <= 60000, 1,
        "timeout must be in -1..60000");
    do {
        ready = poll(&descriptor, 1, (int)timeout);
    } while (ready < 0 && errno == EINTR && !wtop_terminal_signal_pending());
    if (ready < 0 && errno != EINTR) return push_errno(L, "poll");
    if (ready > 0 && descriptor.revents & POLLIN) {
        do { count = read(STDIN_FILENO, buffer, sizeof(buffer)); }
        while (count < 0 && errno == EINTR);
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
            return push_errno(L, "read");
    }
    unsigned pending = wtop_terminal_signal_take();
    lua_createtable(L, 0, 5);
    if (count > 0) {
        lua_pushlstring(L, buffer, (size_t)count);
        lua_setfield(L, -2, "data");
    }
    lua_pushboolean(L, (pending & WTOP_TERMINAL_RESIZE) != 0);
    lua_setfield(L, -2, "resize");
    lua_pushboolean(L, (pending & WTOP_TERMINAL_INTERRUPT) != 0);
    lua_setfield(L, -2, "interrupt");
    lua_pushboolean(L, (pending & WTOP_TERMINAL_TERMINATE) != 0);
    lua_setfield(L, -2, "terminate");
    lua_pushboolean(L, (pending & WTOP_TERMINAL_HANGUP) != 0 || (descriptor.revents & POLLHUP));
    lua_setfield(L, -2, "hangup");

    return 1;
}

static int l_write(lua_State *L) {
    size_t length, offset = 0;
    const char *data = luaL_checklstring(L, 1, &length);
    while (offset < length) {
        ssize_t count = write(STDOUT_FILENO, data + offset, length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return push_errno(L, "write");
        offset += (size_t)count;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_isatty(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    lua_pushboolean(L, isatty(fd));
    return 1;
}

static int l_monotonic_ns(lua_State *L) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0)
        return push_errno(L, "clock_gettime(CLOCK_MONOTONIC)");
    lua_pushinteger(L, (lua_Integer)value.tv_sec * 1000000000LL + value.tv_nsec);
    return 1;
}

static int l_realtime_ns(lua_State *L) {
    struct timespec value;
    if (clock_gettime(CLOCK_REALTIME, &value) != 0)
        return push_errno(L, "clock_gettime(CLOCK_REALTIME)");
    lua_pushinteger(L, (lua_Integer)value.tv_sec * 1000000000LL + value.tv_nsec);
    return 1;
}

static int l_sleep_ms(lua_State *L) {
    lua_Integer milliseconds = luaL_checkinteger(L, 1);
    struct timespec requested, remaining;
    luaL_argcheck(L, milliseconds >= 0 && milliseconds <= 60000, 1,
        "sleep must be in 0..60000");
    requested.tv_sec = (time_t)(milliseconds / 1000);
    requested.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
    while (nanosleep(&requested, &remaining) != 0) {
        if (errno != EINTR) return push_errno(L, "nanosleep");
        requested = remaining;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_uname(lua_State *L) {
    struct utsname value;
    if (uname(&value) != 0) return push_errno(L, "uname");
    lua_createtable(L, 0, 5);
    string_field(L, "sysname", value.sysname);
    string_field(L, "nodename", value.nodename);
    string_field(L, "release", value.release);
    string_field(L, "version", value.version);
    string_field(L, "machine", value.machine);
    return 1;
}

static int l_pid(lua_State *L) {
    lua_pushinteger(L, getpid());
    return 1;
}

static int l_uid(lua_State *L) {
    lua_pushinteger(L, getuid());
    lua_pushinteger(L, geteuid());
    return 2;
}

static int l_system_constants(lua_State *L) {
    lua_createtable(L, 0, 3);
    integer_field(L, "clock_ticks_per_second", 100);
    integer_field(L, "page_size_bytes", (lua_Integer)sysconf(_SC_PAGESIZE));
    string_field(L, "build_revision", WTOP_BUILD_REVISION);
    return 1;
}

static int l_access(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    const char *requested = luaL_optstring(L, 2, "f");
    int mode = F_OK;
    if (strchr(requested, 'r')) mode |= R_OK;
    if (strchr(requested, 'w')) mode |= W_OK;
    if (strchr(requested, 'x')) mode |= X_OK;
    lua_pushboolean(L, access(path, mode) == 0);
    return 1;
}

static int l_readfile(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_Integer requested = luaL_optinteger(L, 2, 4 * 1024 * 1024);
    struct stat metadata;
    char *buffer;
    size_t length = 0, limit;
    int fd;
    luaL_argcheck(L, requested >= 1 && requested <= 64 * 1024 * 1024, 2,
        "limit must be in 1..67108864");
    limit = (size_t)requested;
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return push_errno(L, "open");
    if (fstat(fd, &metadata) != 0) {
        int code = errno;
        (void)close(fd);
        errno = code;
        return push_errno(L, "fstat");
    }
    if (!S_ISREG(metadata.st_mode)) {
        (void)close(fd);
        errno = EINVAL;
        return push_errno(L, "readfile_not_regular");
    }
    buffer = (char *)malloc(limit + 1);
    if (!buffer) {
        (void)close(fd);
        return luaL_error(L, "out of memory reading file");
    }
    while (length <= limit) {
        ssize_t count = read(fd, buffer + length, limit + 1 - length);
        if (count > 0) length += (size_t)count;
        else if (count == 0) break;
        else if (errno != EINTR) {
            int code = errno;
            free(buffer);
            (void)close(fd);
            errno = code;
            return push_errno(L, "read");
        }
    }
    if (close(fd) != 0) {
        int code = errno;
        free(buffer);
        errno = code;
        return push_errno(L, "close");
    }
    if (length > limit) {
        free(buffer);
        errno = EFBIG;
        return push_errno(L, "readfile_limit");
    }
    lua_pushlstring(L, buffer, length);
    free(buffer);
    return 1;
}

static int l_listdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_Integer limit = luaL_optinteger(L, 2, INT_MAX);
    DIR *directory;
    struct dirent *entry;
    int index = 1, truncated = 0;
    luaL_argcheck(L, limit >= 1 && limit <= INT_MAX, 2,
        "limit must be in 1..INT_MAX");
    directory = opendir(path);
    if (!directory) return push_errno(L, "opendir");
    lua_createtable(L, 32, 0);
    errno = 0;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        if (index > limit) { truncated = 1; break; }
        lua_pushstring(L, entry->d_name);
        lua_rawseti(L, -2, index++);
        errno = 0;
    }
    if (errno != 0) {
        int code = errno;
        (void)closedir(directory);
        errno = code;
        return push_errno(L, "readdir");
    }
    if (closedir(directory) != 0) return push_errno(L, "closedir");
    lua_pushnil(L);
    lua_pushboolean(L, truncated);
    return 3;
}

static int l_path_type(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int follow = lua_toboolean(L, 2);
    struct stat metadata;
    const char *kind;
    if ((follow ? stat(path, &metadata) : lstat(path, &metadata)) != 0)
        return push_errno(L, follow ? "stat" : "lstat");
    if (S_ISDIR(metadata.st_mode)) kind = "directory";
    else if (S_ISREG(metadata.st_mode)) kind = "regular";
    else if (S_ISLNK(metadata.st_mode)) kind = "symlink";
    else if (S_ISFIFO(metadata.st_mode)) kind = "fifo";
    else if (S_ISSOCK(metadata.st_mode)) kind = "socket";
    else if (S_ISCHR(metadata.st_mode)) kind = "character_device";
    else if (S_ISBLK(metadata.st_mode)) kind = "block_device";
    else kind = "other";
    lua_pushstring(L, kind);
    return 1;
}

static int l_mkdir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_Integer mode = luaL_optinteger(L, 2, 0700);
    struct stat metadata;
    luaL_argcheck(L, mode >= 0 && mode <= 0777, 2,
        "mode must be in 0000..0777");
    if (mkdir(path, (mode_t)mode) == 0
        || (errno == EEXIST && stat(path, &metadata) == 0
            && S_ISDIR(metadata.st_mode))) {
        lua_pushboolean(L, 1);
        return 1;
    }
    return push_errno(L, "mkdir");
}

static int l_atomic_write(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    size_t length, offset = 0, path_length = strlen(path);
    const char *content = luaL_checklstring(L, 2, &length);
    lua_Integer mode = luaL_optinteger(L, 3, 0600);
    char *temporary;
    int fd;
    luaL_argcheck(L, mode >= 0 && mode <= 0777, 3,
        "mode must be in 0000..0777");
    temporary = (char *)malloc(path_length + 32);
    if (!temporary) return luaL_error(L, "out of memory writing file");
    snprintf(temporary, path_length + 32, "%s.wtop-XXXXXX", path);
    fd = mkstemp(temporary);
    if (fd < 0) {
        free(temporary);
        return push_errno(L, "mkstemp");
    }
    if (fchmod(fd, (mode_t)mode) != 0) goto failed;
    while (offset < length) {
        ssize_t written = write(fd, content + offset, length - offset);
        if (written > 0) offset += (size_t)written;
        else if (written < 0 && errno == EINTR) continue;
        else goto failed;
    }
    if (fsync(fd) != 0) goto failed;
    if (close(fd) != 0) {
        fd = -1;
        goto failed;
    }
    fd = -1;
    if (rename(temporary, path) != 0) goto failed;
    free(temporary);
    lua_pushboolean(L, 1);
    return 1;
failed:
    {
        int code = errno;
        if (fd >= 0) (void)close(fd);
        (void)unlink(temporary);
        free(temporary);
        errno = code;
    }
    return push_errno(L, "atomic_write");
}

static int l_wcwidth(lua_State *L) {
    lua_Integer codepoint = luaL_checkinteger(L, 1);
    int width;
    locale_t previous = (locale_t)0;
    if (codepoint < 0 || codepoint > 0x10ffff) {
        lua_pushinteger(L, -1);
        return 1;
    }
    if (width_locale == (locale_t)0)
        width_locale = newlocale(LC_CTYPE_MASK, "", (locale_t)0);
    if (width_locale != (locale_t)0) previous = uselocale(width_locale);
    width = wcwidth((wchar_t)codepoint);
    if (previous != (locale_t)0) (void)uselocale(previous);
    lua_pushinteger(L, width);
    return 1;
}

static int l_collect_memory(lua_State *L) {
    uint64_t total, used, cache, free_bytes, app, wired, compressed;
    uint64_t swap_total = 0, swap_used = 0;
    size_t length = sizeof(total);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    struct xsw_usage swap;
    uint64_t page_size = (uint64_t)sysconf(_SC_PAGESIZE);
    if (sysctlbyname("hw.memsize", &total, &length, NULL, 0) != 0)
        return push_errno(L, "sysctlbyname(hw.memsize)");
    if (host_statistics64(wtop_macos_host_port(), HOST_VM_INFO64,
        (host_info64_t)&vm, &count) != KERN_SUCCESS) {
        lua_pushnil(L);
        lua_pushliteral(L, "host_statistics64(HOST_VM_INFO64) failed");
        return 2;
    }
    /* The same split Activity Monitor uses: app memory, wired, and the
     * compressor are in use; file-backed and purgeable pages are cache. */
    app = vm.internal_page_count > vm.purgeable_count
        ? (uint64_t)(vm.internal_page_count - vm.purgeable_count) * page_size : 0;
    wired = (uint64_t)vm.wire_count * page_size;
    compressed = (uint64_t)vm.compressor_page_count * page_size;
    used = app + wired + compressed;
    if (used > total) used = total;
    cache = ((uint64_t)vm.external_page_count + vm.purgeable_count) * page_size;
    if (cache > total - used) cache = total - used;
    free_bytes = total - used - cache;
    length = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &length, NULL, 0) == 0) {
        swap_total = swap.xsu_total;
        swap_used = swap.xsu_used;
        if (swap_used > swap_total) swap_used = swap_total;
    }
    lua_createtable(L, 0, 12);
    integer_field(L, "total_bytes", (lua_Integer)total);
    integer_field(L, "available_bytes", (lua_Integer)(cache + free_bytes));
    integer_field(L, "free_bytes", (lua_Integer)free_bytes);
    integer_field(L, "used_bytes", (lua_Integer)used);
    integer_field(L, "cache_bytes", (lua_Integer)cache);
    integer_field(L, "wired_bytes", (lua_Integer)wired);
    integer_field(L, "compressed_bytes", (lua_Integer)compressed);
    integer_field(L, "swap_total_bytes", (lua_Integer)swap_total);
    integer_field(L, "swap_used_bytes", (lua_Integer)swap_used);
    integer_field(L, "swap_free_bytes", (lua_Integer)(swap_total - swap_used));
    lua_createtable(L, 3, 0);
    lua_createtable(L, 0, 2);
    string_field(L, "id", "used");
    integer_field(L, "bytes", (lua_Integer)used);
    lua_rawseti(L, -2, 1);
    lua_createtable(L, 0, 2);
    string_field(L, "id", "cache");
    integer_field(L, "bytes", (lua_Integer)cache);
    lua_rawseti(L, -2, 2);
    lua_createtable(L, 0, 2);
    string_field(L, "id", "free");
    integer_field(L, "bytes", (lua_Integer)free_bytes);
    lua_rawseti(L, -2, 3);
    lua_setfield(L, -2, "segments");
    return 1;
}

#define USER_CACHE_SIZE 64

typedef struct {
    uid_t uid;
    int used;
    char name[64];
} user_cache_entry;

static user_cache_entry user_cache[USER_CACHE_SIZE];
static int user_cache_next = 0;

/* Directory lookups can reach a network directory service, so each UID is
 * resolved once per run and the answer, including a failure, is reused. */
static const char *user_name(uid_t uid) {
    struct passwd entry, *result = NULL;
    char buffer[2048];
    user_cache_entry *cached;
    for (int index = 0; index < USER_CACHE_SIZE; ++index) {
        if (user_cache[index].used && user_cache[index].uid == uid)
            return user_cache[index].name;
    }
    cached = &user_cache[user_cache_next];
    user_cache_next = (user_cache_next + 1) % USER_CACHE_SIZE;
    if (getpwuid_r(uid, &entry, buffer, sizeof(buffer), &result) == 0
        && result && result->pw_name && result->pw_name[0])
        snprintf(cached->name, sizeof(cached->name), "%s", result->pw_name);
    else
        snprintf(cached->name, sizeof(cached->name), "%u", (unsigned)uid);
    cached->uid = uid;
    cached->used = 1;
    return cached->name;
}

/* The BSD status reports SRUN for runnable and sleeping processes alike, so
 * only the states it does distinguish are passed on. */
static const char *process_state(uint32_t status) {
    switch (status) {
    case SSTOP: return "T";
    case SZOMB: return "Z";
    default: return NULL;
    }
}

static struct kinfo_proc *process_table(size_t *count) {
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t needed = 0;
    if (sysctl(mib, 3, NULL, &needed, NULL, 0) != 0) return NULL;
    if (needed > SIZE_MAX - 64 * sizeof(struct kinfo_proc)) {
        errno = EOVERFLOW;
        return NULL;
    }
    size_t capacity = needed + 64 * sizeof(struct kinfo_proc);
    for (int attempt = 0; attempt < 3; ++attempt) {
        struct kinfo_proc *rows = malloc(capacity);
        if (!rows) { errno = ENOMEM; return NULL; }
        size_t bytes = capacity;
        if (sysctl(mib, 3, rows, &bytes, NULL, 0) == 0) {
            *count = bytes / sizeof(*rows);
            return rows;
        }
        int error = errno;
        free(rows);
        if (error != ENOMEM) { errno = error; return NULL; }
        if (capacity > SIZE_MAX / 2) { errno = EOVERFLOW; return NULL; }
        capacity *= 2;
    }
    errno = ENOMEM;
    return NULL;
}

static int l_collect_process(lua_State *L) {
    size_t count = 0;
    struct kinfo_proc *rows = process_table(&count);
    size_t limit = count < MAX_PROCESS_COUNT ? count : MAX_PROCESS_COUNT;
    int output_index = 1, denied = 0, races = 0, parse_errors = 0;
    if (!rows) return push_errno(L, "sysctl(KERN_PROC_ALL)");
    lua_createtable(L, 0, 4);
    lua_createtable(L, (int)limit, 0);
    for (size_t index = 0; index < limit; ++index) {
        const struct kinfo_proc *entry = &rows[index];
        struct proc_bsdinfo bsd;
        struct proc_taskinfo task;
        char name[PROC_PIDPATHINFO_MAXSIZE] = { 0 };
        char path[PROC_PIDPATHINFO_MAXSIZE] = { 0 };
        char identity[80];
        pid_t pid = entry->kp_proc.p_pid;
        int bsd_bytes, bsd_error, task_bytes, task_error;
        int bsd_ok, task_ok, row_denied = 0;
        if (pid <= 0) continue;
        errno = 0;
        bsd_bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
        bsd_error = errno;
        errno = 0;
        task_bytes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task));
        task_error = errno;
        bsd_ok = bsd_bytes == sizeof(bsd);
        task_ok = task_bytes == sizeof(task);
        if (bsd_ok && (bsd.pbi_start_tvsec != (uint64_t)entry->kp_proc.p_starttime.tv_sec
                || bsd.pbi_start_tvusec != (uint64_t)entry->kp_proc.p_starttime.tv_usec)) {
            ++races;
            continue;
        }
        if (!bsd_ok && (bsd_error == ESRCH || bsd_error == ENOENT)) {
            ++races;
            continue;
        }
        if (!bsd_ok) {
            if (bsd_error == EPERM || bsd_error == EACCES) row_denied = 1;
            else ++parse_errors;
        }
        if (!task_ok) {
            if (task_error == EPERM || task_error == EACCES) row_denied = 1;
            else if (task_error == ESRCH || task_error == ENOENT) ++races;
            else ++parse_errors;
        }
        if (row_denied) ++denied;
        int path_bytes = proc_pidpath(pid, path, sizeof(path));
        if (bsd_ok) proc_name(pid, name, sizeof(name));
        path[sizeof(path) - 1] = '\0';
        name[sizeof(name) - 1] = '\0';
        if (!name[0] && path_bytes > 0) {
            const char *base = strrchr(path, '/');
            snprintf(name, sizeof(name), "%s", base ? base + 1 : path);
        }
        if (!name[0] && entry->kp_proc.p_comm[0])
            snprintf(name, sizeof(name), "%s", entry->kp_proc.p_comm);
        if (!name[0])
            snprintf(name, sizeof(name), "PID %d", pid);
        snprintf(identity, sizeof(identity), "%d:%llu:%llu", pid,
            (unsigned long long)entry->kp_proc.p_starttime.tv_sec,
            (unsigned long long)entry->kp_proc.p_starttime.tv_usec);
        lua_createtable(L, 0, 10);
        integer_field(L, "pid", pid);
        string_field(L, "id", identity);
        string_field(L, "name", name);
        integer_field(L, "starttime_ticks", (lua_Integer)entry->kp_proc.p_starttime.tv_sec
            * 1000000LL + entry->kp_proc.p_starttime.tv_usec);
        uid_t uid = bsd_ok ? bsd.pbi_uid : entry->kp_eproc.e_ucred.cr_uid;
        integer_field(L, "uid", uid);
        string_field(L, "user", user_name(uid));
        integer_field(L, "parent_pid", bsd_ok ? bsd.pbi_ppid : entry->kp_eproc.e_ppid);
        integer_field(L, "nice", bsd_ok ? bsd.pbi_nice : entry->kp_proc.p_nice);
        const char *state = process_state(bsd_ok ? bsd.pbi_status : entry->kp_proc.p_stat);
        if (state) string_field(L, "state", state);
        if (path_bytes > 0)
            string_field(L, "command", path);
        if (task_ok) {
            integer_field(L, "cpu_ticks", (lua_Integer)(wtop_mach_to_ns(
                (uint64_t)task.pti_total_user + task.pti_total_system)
                    / 10000000ULL));
            integer_field(L, "resident_bytes", (lua_Integer)task.pti_resident_size);
            integer_field(L, "virtual_bytes", (lua_Integer)task.pti_virtual_size);
            integer_field(L, "threads", task.pti_threadnum);
        }
        if (!bsd_ok || !task_ok) {
            lua_pushboolean(L, 1);
            lua_setfield(L, -2, "partial");
            string_field(L, "partial_reason", !bsd_ok
                ? ((bsd_error == EPERM || bsd_error == EACCES)
                    ? "process_info_denied" : "process_info_unavailable")
                : ((task_error == EPERM || task_error == EACCES)
                    ? "task_info_denied" : "task_info_unavailable"));
        }
        lua_rawseti(L, -2, output_index++);
    }
    free(rows);
    lua_setfield(L, -2, "list");
    integer_field(L, "scanned", limit);
    integer_field(L, "races", races);
    integer_field(L, "denied", denied);
    integer_field(L, "parse_errors", parse_errors);
    integer_field(L, "process_candidates", count);
    integer_field(L, "process_limit", MAX_PROCESS_COUNT);
    integer_field(L, "clock_ticks_per_second", 100);
    string_field(L, "starttime_unit", "unix_us");
    lua_pushboolean(L, count > MAX_PROCESS_COUNT);
    lua_setfield(L, -2, "truncated");
    return 1;
}

static int push_mounts(lua_State *L) {
    struct statfs *values = NULL;
    int count = getmntinfo(&values, MNT_NOWAIT), output_index = 1;
    if (count <= 0 || !values) return push_errno(L, "getmntinfo");
    lua_createtable(L, 0, 1);
    lua_createtable(L, count, 0);
    for (int index = 0; index < count; ++index) {
        const struct statfs *entry = &values[index];
        uint64_t total = (uint64_t)entry->f_blocks * entry->f_bsize;
        uint64_t free_bytes = (uint64_t)entry->f_bfree * entry->f_bsize;
        uint64_t available = (uint64_t)entry->f_bavail * entry->f_bsize;
        uint64_t used = total >= free_bytes ? total - free_bytes : 0;
        if (total == 0) continue;
        lua_createtable(L, 0, 8);
        string_field(L, "id", entry->f_mntonname);
        string_field(L, "mount_point", entry->f_mntonname);
        string_field(L, "source", entry->f_mntfromname);
        string_field(L, "fs_type", entry->f_fstypename);
        string_field(L, "kind", strcmp(entry->f_fstypename, "devfs") == 0
            ? "pseudo" : entry->f_flags & MNT_LOCAL ? "local" : "network");
        lua_pushboolean(L, (entry->f_flags & MNT_RDONLY) != 0);
        lua_setfield(L, -2, "readonly");
        lua_createtable(L, 0, 4);
        integer_field(L, "total_bytes", (lua_Integer)total);
        integer_field(L, "available_bytes", (lua_Integer)available);
        integer_field(L, "used_bytes", (lua_Integer)used);
        number_field(L, "used_percent", (lua_Number)used * 100 / total);
        lua_setfield(L, -2, "capacity");
        lua_rawseti(L, -2, output_index++);
    }
    lua_setfield(L, -2, "mounts");
    return 1;
}

static int l_collect_mounts(lua_State *L) { return push_mounts(L); }

static int l_collect_system_info(lua_State *L) {
    struct utsname identity;
    struct timeval boot;
    size_t length = sizeof(boot);
    char product[256] = "macOS";
    char version[128] = "";
    struct timespec now;
    if (uname(&identity) != 0) return push_errno(L, "uname");
    size_t product_length = sizeof(product);
    (void)sysctlbyname("kern.osproductversion", product, &product_length, NULL, 0);
    length = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &length, NULL, 0) != 0)
        boot.tv_sec = 0;
    (void)clock_gettime(CLOCK_REALTIME, &now);
    snprintf(version, sizeof(version), "macOS %s", product);
    lua_createtable(L, 0, 5);
    lua_createtable(L, 0, 2);
    string_field(L, "hostname", identity.nodename);
    string_field(L, "architecture", identity.machine);
    lua_setfield(L, -2, "host");
    lua_createtable(L, 0, 3);
    string_field(L, "name", "macOS");
    string_field(L, "pretty_name", version);
    string_field(L, "version", product);
    lua_setfield(L, -2, "distribution");
    lua_createtable(L, 0, 3);
    string_field(L, "type", "Darwin");
    string_field(L, "release", identity.release);
    string_field(L, "version", identity.version);
    lua_setfield(L, -2, "kernel");
    if (boot.tv_sec > 0 && now.tv_sec >= boot.tv_sec)
        number_field(L, "uptime_seconds", (lua_Number)(now.tv_sec - boot.tv_sec));
    return 1;
}

#include "wtop_recording.h"

static const luaL_Reg functions[] = {
    {"terminal_start", l_terminal_start},
    {"terminal_stop", l_terminal_stop},
    {"terminal_size", l_terminal_size},
    {"poll", l_poll},
    {"write", l_write},
    {"isatty", l_isatty},
    {"monotonic_ns", l_monotonic_ns},
    {"realtime_ns", l_realtime_ns},
    {"sleep_ms", l_sleep_ms},
    {"uname", l_uname},
    {"pid", l_pid},
    {"uid", l_uid},
    {"system_constants", l_system_constants},
    {"access", l_access},
    {"readfile", l_readfile},
    {"listdir", l_listdir},
    {"path_type", l_path_type},
    {"mkdir", l_mkdir},
    {"atomic_write", l_atomic_write},
    {"recording_open", l_recording_open},
    {"recording_compress", l_recording_compress},
    {"recording_decompress", l_recording_decompress},
    {"wcwidth", l_wcwidth},
    {"collect_cpu", wtop_collect_cpu},
    {"collect_cpu_info", wtop_collect_cpu_info},
    {"collect_memory", l_collect_memory},
    {"collect_process", l_collect_process},
    {"collect_disk", wtop_collect_disk},
    {"collect_mounts", l_collect_mounts},
    {"collect_network", wtop_collect_network},
    {"collect_system_info", l_collect_system_info},
    {NULL, NULL},
};

int luaopen_wtop_native(lua_State *L) {
    luaL_newlib(L, functions);
    wtop_register_file_errors(L);
    wtop_register_hardware(L);
    string_field(L, "VERSION", WTOP_VERSION);
    return 1;
}
