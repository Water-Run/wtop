#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700

#ifndef __linux__
#error "wtop supports Linux only"
#endif

#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 201710L
#error "wtop_native requires a C17 compiler"
#endif

#include <lua.h>
#include <lauxlib.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>

#ifndef NS_PER_SECOND
#define NS_PER_SECOND 1000000000LL
#endif

#define READFILE_CHUNK_BYTES (16 * 1024)

typedef struct terminal_state {
    int active;
    int input_fd;
    int output_fd;
    int input_flags;
    struct termios saved;
    struct sigaction old_winch;
    struct sigaction old_int;
    struct sigaction old_term;
    struct sigaction old_hup;
    int handlers_installed;
} terminal_state;

static terminal_state g_terminal = {0};
static volatile sig_atomic_t g_resize = 0;
static volatile sig_atomic_t g_interrupt = 0;
static volatile sig_atomic_t g_terminate = 0;
static volatile sig_atomic_t g_hangup = 0;
static int g_atexit_registered = 0;
static locale_t g_wcwidth_locale = (locale_t)0;

#define IO_GUARD_METATABLE "wtop.native.io_guard"

typedef struct io_guard {
    DIR *directory;
    int descriptor;
} io_guard;

static void restore_handlers(void);
static void cleanup_native(void);

static void signal_handler(int signal_number) {
    if (signal_number == SIGWINCH) {
        g_resize = 1;
    } else if (signal_number == SIGINT) {
        g_interrupt = 1;
    } else if (signal_number == SIGTERM) {
        g_terminate = 1;
    } else if (signal_number == SIGHUP) {
        g_hangup = 1;
    }
}

static void emergency_terminal_restore(void) {
    static const char sequence[] =
        "\033[?1000l\033[?1006l\033[?2004l\033[?7h\033[0m\033[?25h\033[?1049l";

    if (!g_terminal.active) {
        return;
    }

    (void)tcsetattr(g_terminal.input_fd, TCSAFLUSH, &g_terminal.saved);
    if (g_terminal.input_flags >= 0) {
        (void)fcntl(g_terminal.input_fd, F_SETFL, g_terminal.input_flags);
    }
    (void)write(g_terminal.output_fd, sequence, sizeof(sequence) - 1);
    g_terminal.active = 0;
}

static void cleanup_native(void) {
    emergency_terminal_restore();
    if (g_wcwidth_locale != (locale_t)0) {
        freelocale(g_wcwidth_locale);
        g_wcwidth_locale = (locale_t)0;
    }
}

static int push_errno(lua_State *L, const char *operation) {
    int saved_errno = errno;
    lua_pushnil(L);
    lua_pushfstring(L, "%s: %s", operation, strerror(saved_errno));
    lua_pushinteger(L, saved_errno);
    return 3;
}

static const char *check_path(lua_State *L, int argument, size_t *length_out) {
    size_t length;
    const char *path = luaL_checklstring(L, argument, &length);
    luaL_argcheck(L, strlen(path) == length, argument, "path cannot contain NUL bytes");
    if (length_out) *length_out = length;
    return path;
}

static int check_fd(lua_State *L, int argument, int default_value) {
    lua_Integer value = luaL_optinteger(L, argument, default_value);
    luaL_argcheck(L, value >= 0 && value <= INT_MAX, argument,
                  "file descriptor must be in 0..INT_MAX");
    return (int)value;
}

static int push_timespec_ns(lua_State *L, const struct timespec *value) {
    lua_Integer seconds = (lua_Integer)value->tv_sec;
    if (seconds < 0 || seconds > (LUA_MAXINTEGER - (lua_Integer)value->tv_nsec) / NS_PER_SECOND) {
        errno = EOVERFLOW;
        return push_errno(L, "clock value out of range");
    }
    lua_pushinteger(L, seconds * NS_PER_SECOND + (lua_Integer)value->tv_nsec);
    return 1;
}

/* Lua errors use longjmp, so ordinary C cleanup after a potentially allocating
 * API call is not reliable.  Keep live descriptors in a to-be-closed userdata;
 * Lua invokes this close method both on a regular C return and while unwinding
 * an allocation error.  __gc is a second, idempotent safety net. */
static int l_io_guard_close(lua_State *L) {
    io_guard *guard = (io_guard *)lua_touserdata(L, 1);
    if (!guard) return 0;
    if (guard->directory) {
        (void)closedir(guard->directory);
        guard->directory = NULL;
    }
    if (guard->descriptor >= 0) {
        (void)close(guard->descriptor);
        guard->descriptor = -1;
    }
    return 0;
}

static io_guard *push_io_guard(lua_State *L) {
    io_guard *guard = (io_guard *)lua_newuserdatauv(L, sizeof(*guard), 0);
    guard->directory = NULL;
    guard->descriptor = -1;
    luaL_setmetatable(L, IO_GUARD_METATABLE);
    lua_toclose(L, -1);
    return guard;
}

static int install_handlers(void) {
    struct sigaction action;

    memset(&action, 0, sizeof(action));
    action.sa_handler = signal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;

    if (sigaction(SIGWINCH, &action, &g_terminal.old_winch) != 0) return -1;
    g_terminal.handlers_installed = 1;
    if (sigaction(SIGINT, &action, &g_terminal.old_int) != 0) goto failed;
    g_terminal.handlers_installed = 2;
    if (sigaction(SIGTERM, &action, &g_terminal.old_term) != 0) goto failed;
    g_terminal.handlers_installed = 3;
    if (sigaction(SIGHUP, &action, &g_terminal.old_hup) != 0) goto failed;
    g_terminal.handlers_installed = 4;
    return 0;

failed:
    {
        int saved_errno = errno;
        restore_handlers();
        errno = saved_errno;
    }
    return -1;
}

static void restore_handlers(void) {
    if (g_terminal.handlers_installed >= 1) {
        (void)sigaction(SIGWINCH, &g_terminal.old_winch, NULL);
    }
    if (g_terminal.handlers_installed >= 2) {
        (void)sigaction(SIGINT, &g_terminal.old_int, NULL);
    }
    if (g_terminal.handlers_installed >= 3) {
        (void)sigaction(SIGTERM, &g_terminal.old_term, NULL);
    }
    if (g_terminal.handlers_installed >= 4) {
        (void)sigaction(SIGHUP, &g_terminal.old_hup, NULL);
    }
    g_terminal.handlers_installed = 0;
}

static int l_terminal_start(lua_State *L) {
    int input_fd = check_fd(L, 1, STDIN_FILENO);
    int output_fd = check_fd(L, 2, STDOUT_FILENO);
    struct termios raw;
    int flags;

    if (g_terminal.active) {
        lua_pushboolean(L, 1);
        return 1;
    }

    if (!isatty(input_fd) || !isatty(output_fd)) {
        lua_pushnil(L);
        lua_pushliteral(L, "stdin and stdout must be TTYs");
        lua_pushinteger(L, ENOTTY);
        return 3;
    }

    if (tcgetattr(input_fd, &g_terminal.saved) != 0) {
        return push_errno(L, "tcgetattr");
    }

    raw = g_terminal.saved;
    raw.c_iflag &= (tcflag_t)~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= (tcflag_t)~OPOST;
    raw.c_cflag |= CS8;
    raw.c_lflag &= (tcflag_t)~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;

    if (tcsetattr(input_fd, TCSAFLUSH, &raw) != 0) {
        return push_errno(L, "tcsetattr");
    }

    flags = fcntl(input_fd, F_GETFL, 0);
    if (flags < 0) {
        int saved_errno = errno;
        (void)tcsetattr(input_fd, TCSAFLUSH, &g_terminal.saved);
        errno = saved_errno;
        return push_errno(L, "fcntl");
    }

    /* VMIN=0/VTIME=0 already makes reads non-blocking after poll().  Do not
     * add O_NONBLOCK here: stdin and stdout commonly share one PTY open-file
     * description, so changing the input flags can also make large terminal
     * writes fail with EAGAIN halfway through a frame. */

    g_terminal.input_fd = input_fd;
    g_terminal.output_fd = output_fd;
    g_terminal.input_flags = flags;
    g_terminal.active = 1;
    g_resize = 1;
    g_interrupt = 0;
    g_terminate = 0;
    g_hangup = 0;

    if (install_handlers() != 0) {
        int saved_errno = errno;
        emergency_terminal_restore();
        errno = saved_errno;
        return push_errno(L, "sigaction");
    }

    if (!g_atexit_registered) {
        if (atexit(emergency_terminal_restore) != 0) {
            restore_handlers();
            emergency_terminal_restore();
            lua_pushnil(L);
            lua_pushliteral(L, "atexit registration failed");
            lua_pushinteger(L, EINVAL);
            return 3;
        }
        g_atexit_registered = 1;
    }

    lua_pushboolean(L, 1);
    return 1;
}

static int l_terminal_stop(lua_State *L) {
    (void)L;
    restore_handlers();
    emergency_terminal_restore();
    lua_pushboolean(L, 1);
    return 1;
}

static int l_terminal_size(lua_State *L) {
    struct winsize size;
    int fd = g_terminal.active ? g_terminal.output_fd : STDOUT_FILENO;

    memset(&size, 0, sizeof(size));
    if (ioctl(fd, TIOCGWINSZ, &size) != 0) {
        return push_errno(L, "ioctl(TIOCGWINSZ)");
    }

    lua_pushinteger(L, size.ws_col > 0 ? size.ws_col : 80);
    lua_pushinteger(L, size.ws_row > 0 ? size.ws_row : 24);
    return 2;
}

static int l_poll(lua_State *L) {
    lua_Integer timeout_value = luaL_optinteger(L, 1, -1);
    int timeout_ms;
    int fd = g_terminal.active ? g_terminal.input_fd : STDIN_FILENO;
    struct pollfd descriptor;
    char buffer[4096];
    ssize_t bytes_read = 0;
    int result;

    luaL_argcheck(L, timeout_value >= -1 && timeout_value <= 60000, 1,
                  "timeout must be in -1..60000");
    timeout_ms = (int)timeout_value;
    descriptor.fd = fd;
    descriptor.events = POLLIN | POLLHUP;
    descriptor.revents = 0;

    do {
        result = poll(&descriptor, 1, timeout_ms);
    } while (result < 0 && errno == EINTR &&
             !g_resize && !g_interrupt && !g_terminate && !g_hangup);

    if (result < 0 && errno != EINTR) {
        return push_errno(L, "poll");
    }

    if (result > 0 && (descriptor.revents & POLLIN)) {
        do {
            bytes_read = read(fd, buffer, sizeof(buffer));
        } while (bytes_read < 0 && errno == EINTR);
        if (bytes_read < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            return push_errno(L, "read");
        }
        if (bytes_read < 0) bytes_read = 0;
    }

    lua_createtable(L, 0, 5);
    if (bytes_read > 0) {
        lua_pushlstring(L, buffer, (size_t)bytes_read);
        lua_setfield(L, -2, "data");
    }

    lua_pushboolean(L, g_resize != 0);
    lua_setfield(L, -2, "resize");
    lua_pushboolean(L, g_interrupt != 0);
    lua_setfield(L, -2, "interrupt");
    lua_pushboolean(L, g_terminate != 0);
    lua_setfield(L, -2, "terminate");
    lua_pushboolean(L, g_hangup != 0 || (descriptor.revents & POLLHUP));
    lua_setfield(L, -2, "hangup");

    g_resize = 0;
    g_interrupt = 0;
    g_terminate = 0;
    g_hangup = 0;
    return 1;
}

static int l_write(lua_State *L) {
    size_t length;
    const char *data = luaL_checklstring(L, 1, &length);
    int fd = check_fd(L, 2, STDOUT_FILENO);
    size_t offset = 0;

    while (offset < length) {
        ssize_t count = write(fd, data + offset, length - offset);
        if (count < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd descriptor;
                int result;

                descriptor.fd = fd;
                descriptor.events = POLLOUT;
                descriptor.revents = 0;
                do {
                    result = poll(&descriptor, 1, -1);
                } while (result < 0 && errno == EINTR);
                if (result < 0) return push_errno(L, "poll(write)");
                if (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                    errno = EIO;
                    return push_errno(L, "write");
                }
                continue;
            }
            return push_errno(L, "write");
        }
        if (count == 0) {
            errno = EIO;
            return push_errno(L, "write");
        }
        offset += (size_t)count;
    }

    lua_pushboolean(L, 1);
    return 1;
}

typedef struct captured_stream {
    int fd;
    char *data;
    size_t length;
    size_t capacity;
    int truncated;
} captured_stream;

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static void close_fd(int *fd) {
    if (*fd >= 0) {
        (void)close(*fd);
        *fd = -1;
    }
}

static int make_pipe(int descriptors[2]) {
    if (pipe(descriptors) != 0) return -1;
    if (set_cloexec(descriptors[0]) != 0) {
        int saved_errno = errno;
        (void)close(descriptors[0]);
        (void)close(descriptors[1]);
        descriptors[0] = -1;
        descriptors[1] = -1;
        errno = saved_errno;
        return -1;
    }
    if (set_cloexec(descriptors[1]) != 0) {
        int saved_errno = errno;
        (void)close(descriptors[0]);
        (void)close(descriptors[1]);
        descriptors[0] = -1;
        descriptors[1] = -1;
        errno = saved_errno;
        return -1;
    }
    return 0;
}

typedef struct wtop_linux_dirent64 {
    uint64_t inode;
    int64_t offset;
    unsigned short record_length;
    unsigned char type;
    char name[];
} wtop_linux_dirent64;

static int descriptor_name(const char *name, int *descriptor) {
    unsigned long value = 0;
    const unsigned char *cursor = (const unsigned char *)name;
    if (*cursor == '\0') return 0;
    while (*cursor != '\0') {
        if (*cursor < '0' || *cursor > '9') return 0;
        value = value * 10 + (unsigned long)(*cursor - '0');
        if (value > 0x7fffffffUL) return 0;
        ++cursor;
    }
    *descriptor = (int)value;
    return 1;
}

static int close_from_proc(void) {
#ifdef SYS_getdents64
    _Alignas(uint64_t) char buffer[8192];
    int directory_fd = open("/proc/self/fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (directory_fd < 0) return -1;
    for (;;) {
        long length = syscall(SYS_getdents64, directory_fd, buffer, sizeof(buffer));
        if (length == 0) break;
        if (length < 0) {
            if (errno == EINTR) continue;
            (void)close(directory_fd);
            return -1;
        }
        for (long offset = 0; offset < length;) {
            wtop_linux_dirent64 *entry = (wtop_linux_dirent64 *)(void *)(buffer + offset);
            int descriptor;
            if (entry->record_length == 0 || offset + entry->record_length > length) {
                (void)close(directory_fd);
                errno = EPROTO;
                return -1;
            }
            if (descriptor_name(entry->name, &descriptor)
                && descriptor >= 3 && descriptor != directory_fd) {
                (void)close(descriptor);
            }
            offset += entry->record_length;
        }
    }
    (void)close(directory_fd);
    return 0;
#else
    errno = ENOSYS;
    return -1;
#endif
}

static void close_extra_fds(long maximum_fd) {
#ifdef SYS_close_range
    if (syscall(SYS_close_range, 3u, ~0u, 0u) == 0) return;
#endif
    if (close_from_proc() == 0) return;
    if (maximum_fd < 0) maximum_fd = 65536;
    if (maximum_fd > 1048576) maximum_fd = 1048576;
    for (long fd = 3; fd < maximum_fd; ++fd) {
        (void)close((int)fd);
    }
}

static char *make_environment_assignment(const char *name, const char *value) {
    size_t name_length = strlen(name);
    size_t value_length = strlen(value);
    char *result = (char *)malloc(name_length + value_length + 2);
    if (!result) return NULL;
    memcpy(result, name, name_length);
    result[name_length] = '=';
    memcpy(result + name_length + 1, value, value_length + 1);
    return result;
}

static int capture_init(captured_stream *stream, int fd, size_t capacity) {
    memset(stream, 0, sizeof(*stream));
    stream->fd = fd;
    stream->capacity = capacity;
    stream->data = (char *)malloc(capacity);
    if (!stream->data) return -1;
    return 0;
}

static int capture_drain(captured_stream *stream) {
    char buffer[8192];

    while (stream->fd >= 0) {
        ssize_t count = read(stream->fd, buffer, sizeof(buffer));
        if (count > 0) {
            size_t available = stream->capacity - stream->length;
            size_t copy_length = (size_t)count < available ? (size_t)count : available;
            if (copy_length > 0) {
                memcpy(stream->data + stream->length, buffer, copy_length);
                stream->length += copy_length;
            }
            if (copy_length < (size_t)count) stream->truncated = 1;
            continue;
        }
        if (count == 0) {
            close_fd(&stream->fd);
            return 0;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }
    return 0;
}

static int64_t monotonic_now_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
    return (int64_t)value.tv_sec * NS_PER_SECOND + value.tv_nsec;
}

static int l_run(lua_State *L) {
    size_t argument_count;
    char **arguments = NULL;
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};
    captured_stream stdout_capture = {-1, NULL, 0, 0, 0};
    captured_stream stderr_capture = {-1, NULL, 0, 0, 0};
    lua_Integer timeout_value = 1000;
    lua_Integer max_output_value = 1024 * 1024;
    const char *environment_lang = NULL;
    const char *environment_lc_all = NULL;
    char *lang_assignment = NULL;
    char *lc_all_assignment = NULL;
    char *child_environment[4] = {NULL, NULL, NULL, NULL};
    int cancel_index = 0;
    pid_t child = -1;
    int wait_status = 0;
    int child_done = 0;
    int timed_out = 0;
    int cancelled = 0;
    int internal_error = 0;
    const char *internal_reason = NULL;
    int64_t started_ns;
    int64_t finished_ns;
    long maximum_fd = sysconf(_SC_OPEN_MAX);

    luaL_checktype(L, 1, LUA_TTABLE);
    argument_count = lua_rawlen(L, 1);
    if (argument_count == 0 || argument_count > 128) {
        return luaL_argerror(L, 1, "argv must contain 1..128 strings");
    }

    if (!lua_isnoneornil(L, 2)) {
        luaL_checktype(L, 2, LUA_TTABLE);
        lua_getfield(L, 2, "timeout_ms");
        if (!lua_isnil(L, -1)) timeout_value = luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "max_output_bytes");
        if (!lua_isnil(L, -1)) max_output_value = luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, 2, "env");
        if (!lua_isnil(L, -1)) {
            luaL_checktype(L, -1, LUA_TTABLE);
            lua_getfield(L, -1, "LANG");
            if (!lua_isnil(L, -1)) {
                size_t length;
                environment_lang = luaL_checklstring(L, -1, &length);
                if (strlen(environment_lang) != length || length > 4096) {
                    return luaL_argerror(L, 2, "LANG must contain at most 4096 non-NUL bytes");
                }
            }
            lua_pop(L, 1);
            lua_getfield(L, -1, "LC_ALL");
            if (!lua_isnil(L, -1)) {
                size_t length;
                environment_lc_all = luaL_checklstring(L, -1, &length);
                if (strlen(environment_lc_all) != length || length > 4096) {
                    return luaL_argerror(L, 2, "LC_ALL must contain at most 4096 non-NUL bytes");
                }
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
        lua_getfield(L, 2, "cancel");
        if (!lua_isnil(L, -1)) {
            luaL_checktype(L, -1, LUA_TFUNCTION);
            cancel_index = lua_gettop(L);
        } else {
            lua_pop(L, 1);
        }
    }
    if (timeout_value < 1 || timeout_value > 60000) {
        return luaL_argerror(L, 2, "timeout_ms must be in 1..60000");
    }
    if (max_output_value < 1 || max_output_value > 16 * 1024 * 1024) {
        return luaL_argerror(L, 2, "max_output_bytes must be in 1..16777216");
    }

    started_ns = monotonic_now_ns();
    if (started_ns < 0) return push_errno(L, "clock_gettime(CLOCK_MONOTONIC)");

    arguments = (char **)calloc(argument_count + 1, sizeof(char *));
    if (!arguments) return luaL_error(L, "calloc: out of memory");
    for (size_t index = 0; index < argument_count; ++index) {
        size_t length;
        const char *value;
        lua_rawgeti(L, 1, (lua_Integer)index + 1);
        value = luaL_checklstring(L, -1, &length);
        if (strlen(value) != length) {
            free(arguments);
            return luaL_argerror(L, 1, "argv strings cannot contain NUL bytes");
        }
        arguments[index] = (char *)value;
        lua_pop(L, 1);
    }
    if (arguments[0][0] != '/') {
        free(arguments);
        return luaL_argerror(L, 1, "argv[1] must be an absolute path");
    }

    if (make_pipe(stdout_pipe) != 0) {
        int saved_errno = errno;
        free(arguments);
        errno = saved_errno;
        return push_errno(L, "pipe");
    }
    if (make_pipe(stderr_pipe) != 0) {
        int saved_errno = errno;
        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        free(arguments);
        errno = saved_errno;
        return push_errno(L, "pipe");
    }
    if (set_nonblocking(stdout_pipe[0]) != 0 || set_nonblocking(stderr_pipe[0]) != 0) {
        int saved_errno = errno;
        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[0]);
        close_fd(&stderr_pipe[1]);
        free(arguments);
        errno = saved_errno;
        return push_errno(L, "fcntl");
    }
    if (capture_init(&stdout_capture, stdout_pipe[0], (size_t)max_output_value) != 0 ||
        capture_init(&stderr_capture, stderr_pipe[0], (size_t)max_output_value) != 0) {
        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[0]);
        close_fd(&stderr_pipe[1]);
        free(stdout_capture.data);
        free(stderr_capture.data);
        free(arguments);
        return luaL_error(L, "malloc: out of memory");
    }

    lang_assignment = make_environment_assignment("LANG", environment_lang ? environment_lang : "C");
    lc_all_assignment = make_environment_assignment("LC_ALL", environment_lc_all ? environment_lc_all : "C");
    if (!lang_assignment || !lc_all_assignment) {
        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[0]);
        close_fd(&stderr_pipe[1]);
        free(stdout_capture.data);
        free(stderr_capture.data);
        free(arguments);
        free(lang_assignment);
        free(lc_all_assignment);
        return luaL_error(L, "malloc: out of memory");
    }
    child_environment[0] = lang_assignment;
    child_environment[1] = lc_all_assignment;
    child_environment[2] = (char *)"PATH=/usr/sbin:/usr/bin:/sbin:/bin";

    child = fork();
    if (child < 0) {
        int saved_errno = errno;
        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[0]);
        close_fd(&stderr_pipe[1]);
        free(stdout_capture.data);
        free(stderr_capture.data);
        free(arguments);
        free(lang_assignment);
        free(lc_all_assignment);
        errno = saved_errno;
        return push_errno(L, "fork");
    }

    if (child == 0) {
        struct sigaction action;
        int null_fd;
        if (setpgid(0, 0) != 0) _exit(126);
        memset(&action, 0, sizeof(action));
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        (void)sigaction(SIGINT, &action, NULL);
        (void)sigaction(SIGTERM, &action, NULL);
        (void)sigaction(SIGHUP, &action, NULL);
        (void)sigaction(SIGPIPE, &action, NULL);
        close_fd(&stdout_pipe[0]);
        close_fd(&stderr_pipe[0]);
        null_fd = open("/dev/null", O_RDONLY);
        if (null_fd < 0 || dup2(null_fd, STDIN_FILENO) < 0) {
            _exit(126);
        }
        if (null_fd != STDIN_FILENO) close_fd(&null_fd);
        if (dup2(stdout_pipe[1], STDOUT_FILENO) < 0 ||
            dup2(stderr_pipe[1], STDERR_FILENO) < 0) {
            _exit(126);
        }
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[1]);
        close_extra_fds(maximum_fd);
        execve(arguments[0], arguments, child_environment);
        _exit(errno == ENOENT ? 127 : 126);
    }

    if (setpgid(child, child) != 0 && errno != EACCES && errno != ESRCH) {
        int saved_errno = errno;
        (void)kill(child, SIGKILL);
        (void)waitpid(child, NULL, 0);
        close_fd(&stdout_pipe[0]);
        close_fd(&stdout_pipe[1]);
        close_fd(&stderr_pipe[0]);
        close_fd(&stderr_pipe[1]);
        free(stdout_capture.data);
        free(stderr_capture.data);
        free(arguments);
        free(lang_assignment);
        free(lc_all_assignment);
        errno = saved_errno;
        return push_errno(L, "setpgid");
    }
    free(arguments);
    free(lang_assignment);
    free(lc_all_assignment);
    close_fd(&stdout_pipe[1]);
    close_fd(&stderr_pipe[1]);
    stdout_pipe[0] = -1;
    stderr_pipe[0] = -1;

    while (!child_done || stdout_capture.fd >= 0 || stderr_capture.fd >= 0) {
        struct pollfd descriptors[2];
        captured_stream *streams[2];
        nfds_t descriptor_count = 0;
        int64_t now_ns = monotonic_now_ns();
        int64_t elapsed_ns = now_ns >= 0 && started_ns >= 0 ? now_ns - started_ns : 0;
        int remaining_ms = (int)timeout_value - (int)(elapsed_ns / 1000000);
        int poll_timeout;

        if (cancel_index != 0) {
            lua_pushvalue(L, cancel_index);
            if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
                lua_pop(L, 1);
                internal_error = 1;
                internal_reason = "cancel_callback_failed";
                break;
            }
            cancelled = lua_toboolean(L, -1);
            lua_pop(L, 1);
            if (cancelled) break;
        }

        if (!child_done) {
            siginfo_t information;
            int observed;
            memset(&information, 0, sizeof(information));
            do {
                observed = waitid(P_PID, (id_t)child, &information, WEXITED | WNOHANG | WNOWAIT);
            } while (observed < 0 && errno == EINTR);
            if (observed < 0) {
                internal_error = 1;
                internal_reason = "waitid_failed";
                break;
            } else if (information.si_pid == child) {
                pid_t waited;
                /* Keep the exited group leader unreaped until the group signal
                 * has been sent. This prevents PGID reuse from redirecting
                 * cleanup at an unrelated process group. Optional helpers are
                 * not allowed to leave daemonized work behind. */
                (void)kill(-child, SIGKILL);
                do {
                    waited = waitpid(child, &wait_status, 0);
                } while (waited < 0 && errno == EINTR);
                if (waited != child) {
                    internal_error = 1;
                    internal_reason = "waitpid_failed";
                    break;
                }
                child_done = 1;
            }
        }
        if (remaining_ms <= 0) {
            timed_out = 1;
            break;
        }

        if (stdout_capture.fd >= 0) streams[descriptor_count++] = &stdout_capture;
        if (stderr_capture.fd >= 0) streams[descriptor_count++] = &stderr_capture;
        for (nfds_t index = 0; index < descriptor_count; ++index) {
            descriptors[index].fd = streams[index]->fd;
            descriptors[index].events = POLLIN | POLLHUP;
            descriptors[index].revents = 0;
        }
        poll_timeout = remaining_ms < 50 ? remaining_ms : 50;
        if (poll(descriptors, descriptor_count, poll_timeout) < 0) {
            if (errno == EINTR) continue;
            internal_error = 1;
            internal_reason = "poll_failed";
            break;
        }
        for (nfds_t index = 0; index < descriptor_count; ++index) {
            if (descriptors[index].revents & (POLLIN | POLLHUP | POLLERR)) {
                if (capture_drain(streams[index]) != 0) {
                    internal_error = 1;
                    internal_reason = "read_failed";
                    break;
                }
            }
        }
        if (internal_error) break;
    }

    if (timed_out || cancelled || internal_error) {
        (void)kill(-child, SIGKILL);
        (void)kill(child, SIGKILL);
    }
    if (!child_done) {
        pid_t waited;
        do {
            waited = waitpid(child, &wait_status, 0);
        } while (waited < 0 && errno == EINTR);
        child_done = waited == child;
        if (!child_done && !internal_error) {
            internal_error = 1;
            internal_reason = "waitpid_failed";
        }
    }
    if (capture_drain(&stdout_capture) != 0 && !internal_error) {
        internal_error = 1;
        internal_reason = "read_failed";
    }
    if (capture_drain(&stderr_capture) != 0 && !internal_error) {
        internal_error = 1;
        internal_reason = "read_failed";
    }
    close_fd(&stdout_capture.fd);
    close_fd(&stderr_capture.fd);
    finished_ns = monotonic_now_ns();

    lua_createtable(L, 0, 9);
    if (timed_out) {
        lua_pushliteral(L, "timeout");
    } else if (cancelled) {
        lua_pushliteral(L, "cancelled");
    } else if (internal_error) {
        lua_pushliteral(L, "error");
    } else if (WIFEXITED(wait_status) && WEXITSTATUS(wait_status) == 0) {
        lua_pushliteral(L, "ok");
    } else {
        lua_pushliteral(L, "error");
    }
    lua_setfield(L, -2, "status");
    if (timed_out) {
        lua_pushliteral(L, "timeout");
        lua_setfield(L, -2, "reason");
        lua_pushboolean(L, 1);
        lua_setfield(L, -2, "timed_out");
    } else if (cancelled) {
        lua_pushliteral(L, "cancelled");
        lua_setfield(L, -2, "reason");
    } else if (internal_error) {
        lua_pushstring(L, internal_reason);
        lua_setfield(L, -2, "reason");
    }
    if (child_done && WIFEXITED(wait_status)) {
        lua_pushinteger(L, WEXITSTATUS(wait_status));
        lua_setfield(L, -2, "exit_code");
    }
    if (child_done && WIFSIGNALED(wait_status)) {
        lua_pushinteger(L, WTERMSIG(wait_status));
        lua_setfield(L, -2, "signal");
    }
    lua_pushlstring(L, stdout_capture.data, stdout_capture.length);
    lua_setfield(L, -2, "stdout");
    lua_pushlstring(L, stderr_capture.data, stderr_capture.length);
    lua_setfield(L, -2, "stderr");
    lua_pushboolean(L, stdout_capture.truncated || stderr_capture.truncated);
    lua_setfield(L, -2, "truncated");
    if (started_ns >= 0 && finished_ns >= started_ns) {
        lua_pushinteger(L, (lua_Integer)(finished_ns - started_ns));
        lua_setfield(L, -2, "duration_ns");
    }

    free(stdout_capture.data);
    free(stderr_capture.data);
    return 1;
}

static int l_monotonic_ns(lua_State *L) {
    struct timespec time_value;
    if (clock_gettime(CLOCK_MONOTONIC, &time_value) != 0) {
        return push_errno(L, "clock_gettime(CLOCK_MONOTONIC)");
    }
    return push_timespec_ns(L, &time_value);
}

static int l_realtime_ns(lua_State *L) {
    struct timespec time_value;
    if (clock_gettime(CLOCK_REALTIME, &time_value) != 0) {
        return push_errno(L, "clock_gettime(CLOCK_REALTIME)");
    }
    return push_timespec_ns(L, &time_value);
}

static int l_sleep_ms(lua_State *L) {
    lua_Integer milliseconds = luaL_checkinteger(L, 1);
    struct timespec requested;
    struct timespec remaining;

    if (milliseconds < 0 || milliseconds > 60000) {
        return luaL_argerror(L, 1, "milliseconds must be in 0..60000");
    }
    requested.tv_sec = (time_t)(milliseconds / 1000);
    requested.tv_nsec = (long)((milliseconds % 1000) * 1000000);
    while (nanosleep(&requested, &remaining) != 0) {
        if (errno != EINTR) return push_errno(L, "nanosleep");
        requested = remaining;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_isatty(lua_State *L) {
    int fd = check_fd(L, 1, STDOUT_FILENO);
    lua_pushboolean(L, isatty(fd));
    return 1;
}

static int l_access(lua_State *L) {
    const char *path = check_path(L, 1, NULL);
    const char *requested = luaL_optstring(L, 2, "f");
    int mode = F_OK;

    if (strcmp(requested, "f") != 0 && requested[0] != '\0') {
        mode = 0;
        for (const char *cursor = requested; *cursor != '\0'; ++cursor) {
            if (*cursor == 'r') {
                mode |= R_OK;
            } else if (*cursor == 'w') {
                mode |= W_OK;
            } else if (*cursor == 'x') {
                mode |= X_OK;
            } else {
                return luaL_argerror(L, 2, "mode must contain only r, w, x, or f");
            }
        }
    }
    lua_pushboolean(L, access(path, mode) == 0);
    return 1;
}

static int l_mkdir(lua_State *L) {
    const char *path = check_path(L, 1, NULL);
    lua_Integer mode_value = luaL_optinteger(L, 2, 0700);
    mode_t mode;
    struct stat value;
    if (mode_value < 0 || mode_value > 0777) {
        return luaL_argerror(L, 2, "mode must be in 0000..0777");
    }
    mode = (mode_t)mode_value;
    if (mkdir(path, mode) == 0) {
        lua_pushboolean(L, 1);
        return 1;
    }
    if (errno == EEXIST && stat(path, &value) == 0 && S_ISDIR(value.st_mode)) {
        lua_pushboolean(L, 1);
        return 1;
    }
    return push_errno(L, "mkdir");
}

static int l_atomic_write(lua_State *L) {
    static unsigned long counter = 0;
    const char *path;
    size_t length;
    const char *data = luaL_checklstring(L, 2, &length);
    lua_Integer mode_value = luaL_optinteger(L, 3, 0600);
    mode_t mode;
    size_t path_length;
    char *temporary;
    int fd = -1;
    size_t offset = 0;

    path = check_path(L, 1, &path_length);
    if (path_length == 0 || path_length > 1024 * 1024) {
        return luaL_argerror(L, 1, "path must contain 1..1048576 bytes");
    }
    if (mode_value < 0 || mode_value > 0777) {
        return luaL_argerror(L, 3, "mode must be in 0000..0777");
    }
    mode = (mode_t)mode_value;
    temporary = (char *)malloc(path_length + 96);
    if (!temporary) return luaL_error(L, "malloc: out of memory");

    for (unsigned int attempt = 0; attempt < 100; ++attempt) {
        int count = snprintf(temporary, path_length + 96, "%s.wtop-tmp-%ld-%lu",
            path, (long)getpid(), ++counter);
        if (count < 0 || (size_t)count >= path_length + 96) {
            free(temporary);
            return luaL_error(L, "temporary path formatting failed");
        }
        fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
        if (fd >= 0 || errno != EEXIST) break;
    }
    if (fd < 0) {
        int saved_errno = errno;
        free(temporary);
        errno = saved_errno;
        return push_errno(L, "open temporary file");
    }

    while (offset < length) {
        ssize_t written = write(fd, data + offset, length - offset);
        if (written < 0) {
            if (errno == EINTR) continue;
            goto failed;
        }
        if (written == 0) {
            errno = EIO;
            goto failed;
        }
        offset += (size_t)written;
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
        int saved_errno = errno;
        if (fd >= 0) (void)close(fd);
        (void)unlink(temporary);
        free(temporary);
        errno = saved_errno;
    }
    return push_errno(L, "atomic write");
}

static int l_listdir(lua_State *L) {
    const char *path = check_path(L, 1, NULL);
    int limited = !lua_isnoneornil(L, 2);
    lua_Integer limit = limited ? luaL_checkinteger(L, 2) : 0;
    io_guard *guard;
    struct dirent *entry;
    lua_Integer index = 1;
    int truncated = 0;

    if (limited) {
        luaL_argcheck(L, limit >= 1 && limit <= INT_MAX, 2,
                      "limit must be an integer between 1 and INT_MAX");
    }

    guard = push_io_guard(L);
    guard->directory = opendir(path);
    if (!guard->directory) return push_errno(L, "opendir");

    /* Keep at most limit names and read one extra name solely to report that
       the directory was truncated.  Success is table, nil, boolean. */
    lua_createtable(L, 32, 0);
    errno = 0;
    while ((entry = readdir(guard->directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (limited && index > limit) {
            truncated = 1;
            break;
        }
        lua_pushstring(L, entry->d_name);
        lua_rawseti(L, -2, index++);
    }
    if (errno != 0) {
        int saved_errno = errno;
        lua_pop(L, 1);
        errno = saved_errno;
        return push_errno(L, "readdir");
    }
    lua_pushnil(L);
    lua_pushboolean(L, truncated);
    return 3;
}

static int l_readlink(lua_State *L) {
    const char *path = check_path(L, 1, NULL);
    luaL_Buffer buffer;
    size_t capacity = 256;
    ssize_t length;

    luaL_buffinit(L, &buffer);
    for (;;) {
        char *storage = luaL_prepbuffsize(&buffer, capacity);
        length = readlink(path, storage, capacity);
        if (length < 0) {
            return push_errno(L, "readlink");
        }
        if ((size_t)length < capacity) break;
        if (capacity >= 1024 * 1024) {
            lua_pushnil(L);
            lua_pushliteral(L, "readlink: target exceeds 1 MiB");
            lua_pushinteger(L, ENAMETOOLONG);
            return 3;
        }
        capacity *= 2;
    }

    luaL_pushresultsize(&buffer, (size_t)length);
    return 1;
}

static int l_readfile(lua_State *L) {
    size_t path_length;
    const char *path = check_path(L, 1, &path_length);
    lua_Integer limit_value = luaL_optinteger(L, 2, 4 * 1024 * 1024);
    size_t limit;
    luaL_Buffer output;
    size_t length = 0;
    io_guard *guard;
    struct stat metadata;

    if (limit_value < 1 || limit_value > 64 * 1024 * 1024) {
        return luaL_argerror(L, 2, "limit must be in 1..67108864");
    }
    limit = (size_t)limit_value;
    guard = push_io_guard(L);
    guard->descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW);
    if (guard->descriptor < 0) return push_errno(L, "open");
    if (fstat(guard->descriptor, &metadata) != 0) return push_errno(L, "fstat");
    if (!S_ISREG(metadata.st_mode)) {
        errno = EINVAL;
        return push_errno(L, "readfile_not_regular");
    }
    if (metadata.st_size > 0 && (uintmax_t)metadata.st_size > (uintmax_t)limit) {
        errno = EFBIG;
        return push_errno(L, "readfile_limit");
    }
    luaL_buffinit(L, &output);
    while (length <= limit) {
        size_t remaining = limit + 1 - length;
        size_t request = remaining < READFILE_CHUNK_BYTES ? remaining : READFILE_CHUNK_BYTES;
        char *chunk = luaL_prepbuffsize(&output, request);
        ssize_t count = read(guard->descriptor, chunk, request);
        if (count > 0) {
            luaL_addsize(&output, (size_t)count);
            length += (size_t)count;
            continue;
        }
        if (count == 0) break;
        if (errno == EINTR) continue;
        return push_errno(L, "read");
    }
    if (close(guard->descriptor) != 0) {
        int saved_errno = errno;
        guard->descriptor = -1;
        errno = saved_errno;
        return push_errno(L, "close");
    }
    guard->descriptor = -1;
    if (length > limit) {
        errno = EFBIG;
        return push_errno(L, "readfile_limit");
    }
    luaL_pushresult(&output);
    return 1;
}

static int l_path_type(lua_State *L) {
    const char *path = check_path(L, 1, NULL);
    int follow = 0;
    struct stat metadata;
    const char *kind;

    if (!lua_isnoneornil(L, 2)) {
        luaL_checktype(L, 2, LUA_TBOOLEAN);
        follow = lua_toboolean(L, 2);
    }
    if ((follow ? stat(path, &metadata) : lstat(path, &metadata)) != 0) {
        return push_errno(L, follow ? "stat" : "lstat");
    }
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

static int l_statvfs(lua_State *L) {
    const char *path = check_path(L, 1, NULL);
    struct statvfs value;

    if (statvfs(path, &value) != 0) return push_errno(L, "statvfs");

    lua_createtable(L, 0, 8);
#define SET_UNSIGNED_FIELD(name, field)                                  \
    do {                                                                  \
        uintmax_t field_value = (uintmax_t)value.field;                    \
        if (field_value <= (uintmax_t)LUA_MAXINTEGER) {                    \
            lua_pushinteger(L, (lua_Integer)field_value);                  \
        } else {                                                          \
            lua_pushnumber(L, (lua_Number)field_value);                    \
        }                                                                 \
        lua_setfield(L, -2, name);                                        \
    } while (0)
    SET_UNSIGNED_FIELD("block_size", f_frsize);
    SET_UNSIGNED_FIELD("blocks", f_blocks);
    SET_UNSIGNED_FIELD("blocks_free", f_bfree);
    SET_UNSIGNED_FIELD("blocks_available", f_bavail);
    SET_UNSIGNED_FIELD("files", f_files);
    SET_UNSIGNED_FIELD("files_free", f_ffree);
    SET_UNSIGNED_FIELD("files_available", f_favail);
    SET_UNSIGNED_FIELD("name_max", f_namemax);
    SET_UNSIGNED_FIELD("flags", f_flag);
#undef SET_UNSIGNED_FIELD
    return 1;
}

static int l_system_constants(lua_State *L) {
    long clock_ticks = sysconf(_SC_CLK_TCK);
    long page_size = sysconf(_SC_PAGESIZE);

    if (clock_ticks <= 0 || page_size <= 0) {
        errno = EINVAL;
        return push_errno(L, "sysconf");
    }

    lua_createtable(L, 0, 2);
    lua_pushinteger(L, (lua_Integer)clock_ticks);
    lua_setfield(L, -2, "clock_ticks_per_second");
    lua_pushinteger(L, (lua_Integer)page_size);
    lua_setfield(L, -2, "page_size_bytes");
    return 1;
}

static int read_process_starttime(pid_t pid, unsigned long long *starttime) {
    char path[64];
    char buffer[65536];
    size_t length = 0;
    int fd;
    int count;
    char *closing_parenthesis;
    char *cursor;
    char *end;
    long parsed_pid;

    count = snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
    if (count < 0 || (size_t)count >= sizeof(path)) {
        errno = EINVAL;
        return -1;
    }
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    while (length < sizeof(buffer) - 1) {
        ssize_t bytes_read = read(fd, buffer + length, sizeof(buffer) - 1 - length);
        if (bytes_read > 0) {
            length += (size_t)bytes_read;
            continue;
        }
        if (bytes_read == 0) break;
        if (errno == EINTR) continue;
        {
            int saved_errno = errno;
            (void)close(fd);
            errno = saved_errno;
        }
        return -1;
    }
    if (close(fd) != 0) return -1;
    if (length == sizeof(buffer) - 1) {
        errno = EOVERFLOW;
        return -1;
    }
    buffer[length] = '\0';

    errno = 0;
    parsed_pid = strtol(buffer, &end, 10);
    if (errno != 0 || end == buffer || parsed_pid != (long)pid) {
        errno = EPROTO;
        return -1;
    }
    closing_parenthesis = strrchr(end, ')');
    if (!closing_parenthesis) {
        errno = EPROTO;
        return -1;
    }
    cursor = closing_parenthesis + 1;
    for (int field = 3; field <= 22; ++field) {
        while (*cursor == ' ' || *cursor == '\t') ++cursor;
        if (*cursor == '\0' || *cursor == '\n') {
            errno = EPROTO;
            return -1;
        }
        if (field == 22) {
            unsigned long long value;
            errno = 0;
            value = strtoull(cursor, &end, 10);
            if (errno != 0 || end == cursor || (*end != ' ' && *end != '\t'
                && *end != '\n' && *end != '\0')) {
                errno = EPROTO;
                return -1;
            }
            *starttime = value;
            return 0;
        }
        while (*cursor != '\0' && *cursor != '\n' && *cursor != ' ' && *cursor != '\t') ++cursor;
    }
    errno = EPROTO;
    return -1;
}

static int l_signal_process(lua_State *L) {
    lua_Integer pid_value = luaL_checkinteger(L, 1);
    lua_Integer signal_value = luaL_checkinteger(L, 2);
    lua_Integer expected_value = luaL_checkinteger(L, 3);
    pid_t pid = (pid_t)pid_value;
    int signal_number;
    int pidfd;
    unsigned long long current_starttime;

    if (pid_value <= 0 || (lua_Integer)pid != pid_value) {
        return luaL_argerror(L, 1, "pid must be a positive pid_t value");
    }
    if (signal_value != 0 && signal_value != SIGKILL && signal_value != SIGTERM
        && signal_value != SIGCONT && signal_value != SIGSTOP) {
        return luaL_argerror(L, 2, "signal is not allowed");
    }
    signal_number = (int)signal_value;
    if (expected_value < 0) {
        return luaL_argerror(L, 3, "starttime_ticks must be non-negative");
    }

#if defined(SYS_pidfd_open) && defined(SYS_pidfd_send_signal)
    pidfd = (int)syscall(SYS_pidfd_open, pid, 0u);
    if (pidfd < 0) return push_errno(L, "pidfd_open");
    if (read_process_starttime(pid, &current_starttime) != 0) {
        int saved_errno = errno;
        (void)close(pidfd);
        errno = saved_errno;
        return push_errno(L, "read process identity");
    }
    if (current_starttime != (unsigned long long)expected_value) {
        (void)close(pidfd);
        lua_pushnil(L);
        lua_pushliteral(L, "process identity changed (PID reuse prevented)");
        lua_pushinteger(L, ESTALE);
        return 3;
    }
    if (syscall(SYS_pidfd_send_signal, pidfd, signal_number, NULL, 0u) != 0) {
        int saved_errno = errno;
        (void)close(pidfd);
        errno = saved_errno;
        return push_errno(L, "pidfd_send_signal");
    }
    if (close(pidfd) != 0) return push_errno(L, "close pidfd");
    lua_pushboolean(L, 1);
    return 1;
#else
    (void)pidfd;
    (void)current_starttime;
    lua_pushnil(L);
    lua_pushliteral(L, "pidfd signaling is unavailable on this build");
    lua_pushinteger(L, ENOSYS);
    return 3;
#endif
}

static int l_setpriority(lua_State *L) {
    lua_Integer pid_value = luaL_checkinteger(L, 1);
    lua_Integer priority_value = luaL_checkinteger(L, 2);
    id_t pid = (id_t)pid_value;
    int priority = (int)priority_value;
    if (pid_value <= 0 || (lua_Integer)pid != pid_value) {
        return luaL_argerror(L, 1, "pid must be a positive id_t value");
    }
    if (priority_value < -20 || priority_value > 19 || (lua_Integer)priority != priority_value) {
        return luaL_argerror(L, 2, "priority must be in -20..19");
    }
    if (setpriority(PRIO_PROCESS, pid, priority) != 0) return push_errno(L, "setpriority");
    lua_pushboolean(L, 1);
    return 1;
}

static int l_uid(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)getuid());
    lua_pushinteger(L, (lua_Integer)geteuid());
    return 2;
}

static int l_pid(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)getpid());
    return 1;
}

static int l_uname(lua_State *L) {
    struct utsname value;
    if (uname(&value) != 0) return push_errno(L, "uname");
    lua_createtable(L, 0, 5);
#define SET_STRING_FIELD(name, field) \
    do {                              \
        lua_pushstring(L, value.field); \
        lua_setfield(L, -2, name);    \
    } while (0)
    SET_STRING_FIELD("sysname", sysname);
    SET_STRING_FIELD("nodename", nodename);
    SET_STRING_FIELD("release", release);
    SET_STRING_FIELD("version", version);
    SET_STRING_FIELD("machine", machine);
#undef SET_STRING_FIELD
    return 1;
}

static int l_wcwidth(lua_State *L) {
    lua_Integer codepoint = luaL_checkinteger(L, 1);
    int width;
    locale_t previous_locale = (locale_t)0;
    if (codepoint < 0 || (uint64_t)codepoint > 0x10FFFFu) {
        return luaL_argerror(L, 1, "invalid Unicode codepoint");
    }
    if (g_wcwidth_locale != (locale_t)0) {
        previous_locale = uselocale(g_wcwidth_locale);
    }
    width = wcwidth((wchar_t)codepoint);
    if (previous_locale != (locale_t)0) {
        (void)uselocale(previous_locale);
    }
    lua_pushinteger(L, width);
    return 1;
}

static const luaL_Reg functions[] = {
    {"terminal_start", l_terminal_start},
    {"terminal_stop", l_terminal_stop},
    {"terminal_size", l_terminal_size},
    {"poll", l_poll},
    {"write", l_write},
    {"run", l_run},
    {"monotonic_ns", l_monotonic_ns},
    {"realtime_ns", l_realtime_ns},
    {"sleep_ms", l_sleep_ms},
    {"isatty", l_isatty},
    {"access", l_access},
    {"mkdir", l_mkdir},
    {"atomic_write", l_atomic_write},
    {"listdir", l_listdir},
    {"readfile", l_readfile},
    {"readlink", l_readlink},
    {"path_type", l_path_type},
    {"statvfs", l_statvfs},
    {"system_constants", l_system_constants},
    {"signal_process", l_signal_process},
    {"setpriority", l_setpriority},
    {"uid", l_uid},
    {"pid", l_pid},
    {"uname", l_uname},
    {"wcwidth", l_wcwidth},
    {NULL, NULL},
};

int luaopen_wtop_native(lua_State *L) {
    /* wcwidth needs the user's character locale, but setlocale() mutates
     * process-global ctype state and makes Lua's ASCII upper/lower operations
     * locale-dependent (notably Turkish I).  Keep a dedicated locale and
     * install it only around wcwidth on the current thread. */
    if (g_wcwidth_locale == (locale_t)0) {
        g_wcwidth_locale = newlocale(LC_CTYPE_MASK, "", (locale_t)0);
    }
    if (!g_atexit_registered) {
        if (atexit(cleanup_native) != 0) {
            cleanup_native();
            return luaL_error(L, "atexit registration failed");
        }
        g_atexit_registered = 1;
    }
    if (luaL_newmetatable(L, IO_GUARD_METATABLE)) {
        lua_pushcfunction(L, l_io_guard_close);
        lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, l_io_guard_close);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    luaL_newlib(L, functions);
    lua_pushliteral(L, "0.1.0");
    lua_setfield(L, -2, "VERSION");
    return 1;
}
