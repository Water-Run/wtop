/* macOS backend. Uses Mach, libproc, sysctl and BSD interfaces. */
#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <lua.h>
#include <lauxlib.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IOStorageDeviceCharacteristics.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>

#include <errno.h>
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

#define MAX_PROCESS_COUNT 8192

static struct termios saved_terminal;
static int terminal_active = 0;
static int cleanup_registered = 0;
static volatile sig_atomic_t resized = 0;
static volatile sig_atomic_t interrupted = 0;
static volatile sig_atomic_t terminated = 0;
static volatile sig_atomic_t hung_up = 0;
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
    if (number == SIGWINCH) resized = 1;
    else if (number == SIGINT) interrupted = 1;
    else if (number == SIGTERM) terminated = 1;
    else if (number == SIGHUP) hung_up = 1;
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
    resized = 1;
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
    } while (ready < 0 && errno == EINTR && !resized && !interrupted
        && !terminated && !hung_up);
    if (ready < 0 && errno != EINTR) return push_errno(L, "poll");
    if (ready > 0 && descriptor.revents & POLLIN) {
        do { count = read(STDIN_FILENO, buffer, sizeof(buffer)); }
        while (count < 0 && errno == EINTR);
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
            return push_errno(L, "read");
    }
    lua_createtable(L, 0, 5);
    if (count > 0) {
        lua_pushlstring(L, buffer, (size_t)count);
        lua_setfield(L, -2, "data");
    }
    lua_pushboolean(L, resized != 0);
    lua_setfield(L, -2, "resize");
    lua_pushboolean(L, interrupted != 0);
    lua_setfield(L, -2, "interrupt");
    lua_pushboolean(L, terminated != 0);
    lua_setfield(L, -2, "terminate");
    lua_pushboolean(L, hung_up != 0 || (descriptor.revents & POLLHUP));
    lua_setfield(L, -2, "hangup");
    resized = interrupted = terminated = hung_up = 0;
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
    lua_createtable(L, 0, 2);
    integer_field(L, "clock_ticks_per_second", 100);
    integer_field(L, "page_size_bytes", (lua_Integer)sysconf(_SC_PAGESIZE));
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

static int l_collect_cpu(lua_State *L) {
    host_cpu_load_info_data_t cpu;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_msg_type_number_t processor_info_count = 0;
    natural_t processor_count = 0;
    processor_info_array_t processor_info = NULL;
    processor_cpu_load_info_t processors;
    uint64_t busy, total;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
        (host_info_t)&cpu, &count) != KERN_SUCCESS) {
        lua_pushnil(L);
        lua_pushliteral(L, "host_statistics(HOST_CPU_LOAD_INFO) failed");
        return 2;
    }
    busy = (uint64_t)cpu.cpu_ticks[CPU_STATE_USER]
        + cpu.cpu_ticks[CPU_STATE_SYSTEM] + cpu.cpu_ticks[CPU_STATE_NICE];
    total = busy + cpu.cpu_ticks[CPU_STATE_IDLE];
    lua_createtable(L, 0, 2);
    lua_createtable(L, 0, 2);
    integer_field(L, "busy", (lua_Integer)busy);
    integer_field(L, "total", (lua_Integer)total);
    lua_setfield(L, -2, "raw");
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
        &processor_count, &processor_info, &processor_info_count) != KERN_SUCCESS)
        processor_count = 0;
    processors = (processor_cpu_load_info_t)processor_info;
    lua_createtable(L, (int)processor_count, 0);
    for (natural_t index = 0; index < processor_count; ++index) {
        uint64_t core_busy = (uint64_t)processors[index].cpu_ticks[CPU_STATE_USER]
            + processors[index].cpu_ticks[CPU_STATE_SYSTEM]
            + processors[index].cpu_ticks[CPU_STATE_NICE];
        uint64_t core_total = core_busy
            + processors[index].cpu_ticks[CPU_STATE_IDLE];
        lua_createtable(L, 0, 2);
        lua_pushfstring(L, "cpu%d", (int)index);
        lua_setfield(L, -2, "name");
        lua_createtable(L, 0, 2);
        integer_field(L, "busy", (lua_Integer)core_busy);
        integer_field(L, "total", (lua_Integer)core_total);
        lua_setfield(L, -2, "raw");
        lua_rawseti(L, -2, (lua_Integer)index + 1);
    }
    lua_setfield(L, -2, "cores");
    if (processor_info != NULL)
        (void)vm_deallocate(mach_task_self(), (vm_address_t)processor_info,
            (vm_size_t)processor_info_count * sizeof(integer_t));
    return 1;
}

static int sysctl_text(const char *name, char *output, size_t size) {
    size_t length = size - 1;
    memset(output, 0, size);
    if (sysctlbyname(name, output, &length, NULL, 0) != 0 || length == 0) return 0;
    output[size - 1] = 0;
    return output[0] != 0;
}

static int sysctl_integer(const char *name, int64_t *value) {
    unsigned char buffer[8] = {0};
    size_t length = sizeof(buffer);
    *value = 0;
    if (sysctlbyname(name, buffer, &length, NULL, 0) != 0) return 0;
    if (length == sizeof(int32_t)) {
        int32_t narrow;
        memcpy(&narrow, buffer, sizeof(narrow));
        *value = narrow;
    } else if (length == sizeof(int64_t)) {
        memcpy(value, buffer, sizeof(*value));
    } else {
        return 0;
    }
    return 1;
}

typedef struct {
    int level;
    const char *type;
    int64_t instances;
    int64_t total;
} cache_total;

static void add_cache(cache_total *caches, int *count, int level, const char *type,
    int64_t size, int64_t instances) {
    if (size <= 0 || instances <= 0) return;
    for (int index = 0; index < *count; ++index) {
        if (caches[index].level == level && strcmp(caches[index].type, type) == 0) {
            caches[index].instances += instances;
            caches[index].total += size * instances;
            return;
        }
    }
    if (*count >= 8) return;
    caches[*count].level = level;
    caches[*count].type = type;
    caches[*count].instances = instances;
    caches[*count].total = size * instances;
    ++*count;
}

static int l_collect_cpu_info(lua_State *L) {
    int64_t logical = 0, physical = 0, packages = 0, levels = 0, value = 0;
    char text[256];
    cache_total caches[8];
    int cache_count = 0;
    if (!sysctl_integer("hw.logicalcpu", &logical))
        return push_errno(L, "sysctlbyname(hw.logicalcpu)");
    (void)sysctl_integer("hw.physicalcpu", &physical);
    (void)sysctl_integer("hw.packages", &packages);
    (void)sysctl_integer("hw.nperflevels", &levels);
    lua_createtable(L, 0, 4);
    lua_createtable(L, 0, 6);
    if (sysctl_text("machdep.cpu.brand_string", text, sizeof(text)))
        string_field(L, "model_name", text);
    if (sysctl_text("machdep.cpu.vendor", text, sizeof(text)))
        string_field(L, "vendor", text);
#if defined(__arm64__)
    else
        string_field(L, "vendor", "Apple");
#endif
    if (sysctl_integer("machdep.cpu.family", &value)) integer_field(L, "family", value);
    if (sysctl_integer("machdep.cpu.model", &value)) integer_field(L, "model", value);
    if (sysctl_integer("machdep.cpu.stepping", &value)) integer_field(L, "stepping", value);
    lua_pushboolean(L, levels > 1);
    lua_setfield(L, -2, "heterogeneous");
    lua_setfield(L, -2, "identity");
    lua_createtable(L, 0, 3);
    integer_field(L, "threads", logical);
    if (physical > 0) integer_field(L, "physical_cores", physical);
    if (packages > 0) integer_field(L, "sockets", packages);
    lua_setfield(L, -2, "topology");
    lua_createtable(L, (int)(levels > 0 ? levels : 0), 0);
    if (levels > 0) {
        /* Apple silicon groups cores into performance levels, each with its
         * own core count and cache sizes. */
        for (int64_t level = 0; level < levels && level < 8; ++level) {
            char name[64];
            int64_t level_logical = 0, level_physical = 0, size = 0, sharing = 0;
            snprintf(name, sizeof(name), "hw.perflevel%lld.logicalcpu", (long long)level);
            (void)sysctl_integer(name, &level_logical);
            snprintf(name, sizeof(name), "hw.perflevel%lld.physicalcpu", (long long)level);
            (void)sysctl_integer(name, &level_physical);
            lua_createtable(L, 0, 4);
            lua_pushfstring(L, "type-%d", (int)level + 1);
            lua_setfield(L, -2, "id");
            snprintf(name, sizeof(name), "hw.perflevel%lld.name", (long long)level);
            if (sysctl_text(name, text, sizeof(text))) string_field(L, "model_name", text);
            integer_field(L, "logical_cpu_count", level_logical);
            integer_field(L, "physical_core_count", level_physical);
            lua_rawseti(L, -2, (lua_Integer)level + 1);
            snprintf(name, sizeof(name), "hw.perflevel%lld.l1dcachesize", (long long)level);
            if (sysctl_integer(name, &size)) add_cache(caches, &cache_count, 1, "Data", size, level_physical);
            snprintf(name, sizeof(name), "hw.perflevel%lld.l1icachesize", (long long)level);
            if (sysctl_integer(name, &size)) add_cache(caches, &cache_count, 1, "Instruction", size, level_physical);
            snprintf(name, sizeof(name), "hw.perflevel%lld.cpusperl2", (long long)level);
            (void)sysctl_integer(name, &sharing);
            snprintf(name, sizeof(name), "hw.perflevel%lld.l2cachesize", (long long)level);
            if (sysctl_integer(name, &size) && sharing > 0)
                add_cache(caches, &cache_count, 2, "Unified", size, level_logical / sharing);
            snprintf(name, sizeof(name), "hw.perflevel%lld.cpusperl3", (long long)level);
            sharing = 0;
            (void)sysctl_integer(name, &sharing);
            snprintf(name, sizeof(name), "hw.perflevel%lld.l3cachesize", (long long)level);
            if (sysctl_integer(name, &size) && sharing > 0)
                add_cache(caches, &cache_count, 3, "Unified", size, level_logical / sharing);
        }
    } else {
        /* hw.cacheconfig lists how many logical CPUs share each cache level. */
        uint64_t sharing[8] = {0};
        size_t length = sizeof(sharing);
        int64_t size = 0;
        if (sysctlbyname("hw.cacheconfig", sharing, &length, NULL, 0) != 0) length = 0;
        if (length >= 2 * sizeof(uint64_t) && sharing[1] > 0) {
            if (sysctl_integer("hw.l1dcachesize", &size))
                add_cache(caches, &cache_count, 1, "Data", size, logical / (int64_t)sharing[1]);
            if (sysctl_integer("hw.l1icachesize", &size))
                add_cache(caches, &cache_count, 1, "Instruction", size, logical / (int64_t)sharing[1]);
        }
        if (length >= 3 * sizeof(uint64_t) && sharing[2] > 0
            && sysctl_integer("hw.l2cachesize", &size))
            add_cache(caches, &cache_count, 2, "Unified", size, logical / (int64_t)sharing[2]);
        if (length >= 4 * sizeof(uint64_t) && sharing[3] > 0
            && sysctl_integer("hw.l3cachesize", &size))
            add_cache(caches, &cache_count, 3, "Unified", size, logical / (int64_t)sharing[3]);
    }
    lua_setfield(L, -2, "core_types");
    lua_createtable(L, cache_count, 0);
    for (int index = 0; index < cache_count; ++index) {
        lua_createtable(L, 0, 5);
        lua_pushfstring(L, "L%d:%s", caches[index].level, caches[index].type);
        lua_setfield(L, -2, "id");
        integer_field(L, "level", caches[index].level);
        string_field(L, "type", caches[index].type);
        integer_field(L, "instances", caches[index].instances);
        integer_field(L, "total_size_bytes", caches[index].total);
        lua_rawseti(L, -2, index + 1);
    }
    lua_setfield(L, -2, "cache_summary");
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
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
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

static int l_collect_process(lua_State *L) {
    pid_t pids[MAX_PROCESS_COUNT];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));
    int count, output_index = 1;
    if (bytes < 0) return push_errno(L, "proc_listpids");
    count = bytes / (int)sizeof(pid_t);
    lua_createtable(L, 0, 4);
    lua_createtable(L, count, 0);
    for (int index = 0; index < count; ++index) {
        struct proc_bsdinfo bsd;
        struct proc_taskinfo task;
        char name[PROC_PIDPATHINFO_MAXSIZE];
        char path[PROC_PIDPATHINFO_MAXSIZE];
        char identity[80];
        pid_t pid = pids[index];
        int bsd_bytes, task_bytes;
        if (pid <= 0) continue;
        bsd_bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
        task_bytes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task));
        if (bsd_bytes != sizeof(bsd)) continue;
        memset(name, 0, sizeof(name));
        if (proc_name(pid, name, sizeof(name)) <= 0) {
            snprintf(name, sizeof(name), "PID %d", pid);
        }
        snprintf(identity, sizeof(identity), "%d:%llu:%llu", pid,
            (unsigned long long)bsd.pbi_start_tvsec,
            (unsigned long long)bsd.pbi_start_tvusec);
        lua_createtable(L, 0, 10);
        integer_field(L, "pid", pid);
        string_field(L, "id", identity);
        string_field(L, "name", name);
        integer_field(L, "starttime_ticks", (lua_Integer)bsd.pbi_start_tvsec
            * 1000000LL + bsd.pbi_start_tvusec);
        integer_field(L, "uid", bsd.pbi_uid);
        string_field(L, "user", user_name(bsd.pbi_uid));
        integer_field(L, "parent_pid", bsd.pbi_ppid);
        integer_field(L, "nice", bsd.pbi_nice);
        if (process_state(bsd.pbi_status))
            string_field(L, "state", process_state(bsd.pbi_status));
        if (proc_pidpath(pid, path, sizeof(path)) > 0)
            string_field(L, "command", path);
        if (task_bytes == sizeof(task)) {
            integer_field(L, "cpu_ticks", (lua_Integer)(
                ((uint64_t)task.pti_total_user + task.pti_total_system)
                    / 10000000ULL));
            integer_field(L, "resident_bytes", (lua_Integer)task.pti_resident_size);
            integer_field(L, "virtual_bytes", (lua_Integer)task.pti_virtual_size);
            integer_field(L, "threads", task.pti_threadnum);
        }
        lua_rawseti(L, -2, output_index++);
    }
    lua_setfield(L, -2, "list");
    integer_field(L, "process_candidates", count);
    integer_field(L, "process_limit", MAX_PROCESS_COUNT);
    integer_field(L, "clock_ticks_per_second", 100);
    string_field(L, "starttime_unit", "unix_us");
    lua_pushboolean(L, count == MAX_PROCESS_COUNT);
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

static CFTypeRef registry_property(io_registry_entry_t entry, CFStringRef key,
    CFTypeID type) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (value && CFGetTypeID(value) != type) {
        CFRelease(value);
        return NULL;
    }
    return value;
}

static int dictionary_integer(CFDictionaryRef dictionary, CFStringRef key,
    int64_t *value) {
    CFTypeRef number = CFDictionaryGetValue(dictionary, key);
    return number && CFGetTypeID(number) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)number, kCFNumberSInt64Type, value);
}

static void dictionary_string_field(lua_State *L, CFDictionaryRef dictionary,
    CFStringRef key, const char *field) {
    CFTypeRef value = dictionary ? CFDictionaryGetValue(dictionary, key) : NULL;
    char text[256];
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return;
    if (!CFStringGetCString((CFStringRef)value, text, sizeof(text),
        kCFStringEncodingUTF8)) return;
    for (size_t length = strlen(text); length > 0 && text[length - 1] == ' '; )
        text[--length] = 0;
    if (text[0]) string_field(L, field, text);
}

static void counter_field(lua_State *L, CFDictionaryRef statistics, CFStringRef key,
    const char *field) {
    int64_t value;
    if (dictionary_integer(statistics, key, &value) && value >= 0)
        integer_field(L, field, value);
}

static int l_collect_disk(lua_State *L) {
    io_iterator_t iterator = 0;
    io_registry_entry_t driver;
    int output_index = 1;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL,
        IOServiceMatching(kIOBlockStorageDriverClass), &iterator) != KERN_SUCCESS) {
        lua_pushnil(L);
        lua_pushliteral(L, "IOServiceGetMatchingServices failed");
        return 2;
    }
    lua_createtable(L, 0, 1);
    lua_createtable(L, 4, 0);
    while ((driver = IOIteratorNext(iterator)) != 0) {
        io_registry_entry_t media = 0, device = 0;
        CFDictionaryRef statistics = registry_property(driver,
            CFSTR(kIOBlockStorageDriverStatisticsKey), CFDictionaryGetTypeID());
        CFDictionaryRef characteristics = NULL, protocol = NULL;
        CFStringRef bsd_name = NULL;
        CFNumberRef size = NULL;
        CFBooleanRef removable = NULL;
        char name[64] = "";
        if (IORegistryEntryGetChildEntry(driver, kIOServicePlane, &media) == KERN_SUCCESS) {
            bsd_name = registry_property(media, CFSTR(kIOBSDNameKey), CFStringGetTypeID());
            size = registry_property(media, CFSTR(kIOMediaSizeKey), CFNumberGetTypeID());
            removable = registry_property(media, CFSTR(kIOMediaRemovableKey),
                CFBooleanGetTypeID());
        }
        if (IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS) {
            characteristics = registry_property(device,
                CFSTR(kIOPropertyDeviceCharacteristicsKey), CFDictionaryGetTypeID());
            protocol = registry_property(device,
                CFSTR(kIOPropertyProtocolCharacteristicsKey), CFDictionaryGetTypeID());
        }
        if (bsd_name)
            (void)CFStringGetCString(bsd_name, name, sizeof(name), kCFStringEncodingUTF8);
        if (name[0] && statistics) {
            int64_t bytes = 0;
            lua_createtable(L, 0, 6);
            string_field(L, "id", name);
            string_field(L, "name", name);
            lua_pushboolean(L, 1);
            lua_setfield(L, -2, "aggregate");
            lua_createtable(L, 0, 7);
            dictionary_string_field(L, characteristics, CFSTR(kIOPropertyProductNameKey), "model");
            dictionary_string_field(L, characteristics, CFSTR(kIOPropertyVendorNameKey), "vendor");
            dictionary_string_field(L, characteristics,
                CFSTR(kIOPropertyProductRevisionLevelKey), "firmware");
            dictionary_string_field(L, protocol, CFSTR(kIOPropertyPhysicalInterconnectTypeKey), "bus");
            if (size && CFNumberGetValue(size, kCFNumberSInt64Type, &bytes) && bytes > 0)
                integer_field(L, "size_bytes", bytes);
            if (characteristics) {
                CFTypeRef medium = CFDictionaryGetValue(characteristics,
                    CFSTR(kIOPropertyMediumTypeKey));
                if (medium && CFGetTypeID(medium) == CFStringGetTypeID()) {
                    if (CFStringCompare((CFStringRef)medium,
                        CFSTR(kIOPropertyMediumTypeSolidStateKey), 0) == kCFCompareEqualTo)
                        integer_field(L, "rotational", 0);
                    else if (CFStringCompare((CFStringRef)medium,
                        CFSTR(kIOPropertyMediumTypeRotationalKey), 0) == kCFCompareEqualTo)
                        integer_field(L, "rotational", 1);
                }
            }
            lua_pushboolean(L, removable && CFBooleanGetValue(removable));
            lua_setfield(L, -2, "removable");
            lua_setfield(L, -2, "identity");
            lua_createtable(L, 0, 6);
            counter_field(L, statistics, CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey), "bytes_read");
            counter_field(L, statistics, CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey), "bytes_written");
            counter_field(L, statistics, CFSTR(kIOBlockStorageDriverStatisticsReadsKey), "reads");
            counter_field(L, statistics, CFSTR(kIOBlockStorageDriverStatisticsWritesKey), "writes");
            counter_field(L, statistics, CFSTR(kIOBlockStorageDriverStatisticsTotalReadTimeKey), "read_time_ns");
            counter_field(L, statistics, CFSTR(kIOBlockStorageDriverStatisticsTotalWriteTimeKey), "write_time_ns");
            lua_setfield(L, -2, "counters");
            lua_rawseti(L, -2, output_index++);
        }
        if (statistics) CFRelease(statistics);
        if (characteristics) CFRelease(characteristics);
        if (protocol) CFRelease(protocol);
        if (bsd_name) CFRelease(bsd_name);
        if (size) CFRelease(size);
        if (removable) CFRelease(removable);
        if (media) IOObjectRelease(media);
        if (device) IOObjectRelease(device);
        IOObjectRelease(driver);
    }
    IOObjectRelease(iterator);
    lua_setfield(L, -2, "devices");
    return 1;
}

static int l_collect_mounts(lua_State *L) { return push_mounts(L); }

static int l_collect_network(lua_State *L) {
    /* NET_RT_IFLIST2 names each interface and its link address. Its byte
     * counters, like the if_data behind getifaddrs, wrap at 4 GiB for an
     * unprivileged caller, so the counters come from the interface MIB. */
    int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t length = 0;
    char *buffer, *next, *end;
    int output_index = 1, all_wide = 1;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || length == 0)
        return push_errno(L, "sysctl(NET_RT_IFLIST2)");
    length += 4096;
    buffer = (char *)malloc(length);
    if (!buffer) return luaL_error(L, "out of memory collecting interfaces");
    if (sysctl(mib, 6, buffer, &length, NULL, 0) != 0) {
        int code = errno;
        free(buffer);
        errno = code;
        return push_errno(L, "sysctl(NET_RT_IFLIST2)");
    }
    lua_createtable(L, 0, 2);
    lua_createtable(L, 16, 0);
    end = buffer + length;
    for (next = buffer; next + sizeof(struct if_msghdr) <= end; ) {
        const struct if_msghdr *header = (const struct if_msghdr *)next;
        const struct if_msghdr2 *message;
        const struct sockaddr_dl *link;
        const struct if_data64 *counters;
        struct ifmibdata interface_mib;
        size_t mib_length = sizeof(interface_mib);
        int mib_query[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, 0,
            IFDATA_GENERAL};
        char name[IFNAMSIZ + 1];
        size_t name_length;
        if (header->ifm_msglen == 0 || next + header->ifm_msglen > end) break;
        next += header->ifm_msglen;
        if (header->ifm_type != RTM_IFINFO2
            || header->ifm_msglen < sizeof(struct if_msghdr2) + sizeof(struct sockaddr_dl))
            continue;
        message = (const struct if_msghdr2 *)header;
        link = (const struct sockaddr_dl *)(message + 1);
        name_length = link->sdl_nlen < IFNAMSIZ ? link->sdl_nlen : IFNAMSIZ;
        memcpy(name, link->sdl_data, name_length);
        name[name_length] = 0;
        if (!name[0]) continue;
        mib_query[4] = message->ifm_index;
        if (sysctl(mib_query, 6, &interface_mib, &mib_length, NULL, 0) == 0
            && mib_length >= sizeof(interface_mib)) {
            counters = &interface_mib.ifmd_data;
        } else {
            counters = &message->ifm_data;
            all_wide = 0;
        }
        lua_createtable(L, 0, 8);
        string_field(L, "id", name);
        string_field(L, "name", name);
        string_field(L, "operstate", message->ifm_flags & IFF_UP
            && message->ifm_flags & IFF_RUNNING ? "up" : "down");
        integer_field(L, "mtu", (lua_Integer)message->ifm_data.ifi_mtu);
        if (message->ifm_data.ifi_baudrate > 0)
            integer_field(L, "speed_mbps",
                (lua_Integer)(message->ifm_data.ifi_baudrate / 1000000));
        if (link->sdl_alen == 6) {
            const unsigned char *mac = (const unsigned char *)LLADDR(link);
            char text[18];
            snprintf(text, sizeof(text), "%02x:%02x:%02x:%02x:%02x:%02x",
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
            string_field(L, "address", text);
        }
        lua_createtable(L, 0, 5);
        integer_field(L, "rx_bytes", (lua_Integer)counters->ifi_ibytes);
        integer_field(L, "tx_bytes", (lua_Integer)counters->ifi_obytes);
        integer_field(L, "rx_errors", (lua_Integer)counters->ifi_ierrors);
        integer_field(L, "tx_errors", (lua_Integer)counters->ifi_oerrors);
        integer_field(L, "rx_drops", (lua_Integer)counters->ifi_iqdrops);
        lua_setfield(L, -2, "counters");
        lua_rawseti(L, -2, output_index++);
    }
    free(buffer);
    lua_setfield(L, -2, "interfaces");
    integer_field(L, "counter_bits", all_wide ? 64 : 32);
    return 1;
}

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
    {"wcwidth", l_wcwidth},
    {"collect_cpu", l_collect_cpu},
    {"collect_cpu_info", l_collect_cpu_info},
    {"collect_memory", l_collect_memory},
    {"collect_process", l_collect_process},
    {"collect_disk", l_collect_disk},
    {"collect_mounts", l_collect_mounts},
    {"collect_network", l_collect_network},
    {"collect_system_info", l_collect_system_info},
    {NULL, NULL},
};

int luaopen_wtop_native(lua_State *L) {
    luaL_newlib(L, functions);
    string_field(L, "VERSION", "macos-0.1");
    return 1;
}
