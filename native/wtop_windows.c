/* Win32 backend. Keep the import set compatible with 32-bit Windows XP.
 * The classic console path uses screen-buffer APIs and never emits VT codes. */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define PSAPI_VERSION 1
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <psapi.h>
#include <iphlpapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>

#define UNIX_FILETIME_TICKS 116444736000000000ULL
#define MAX_PROCESSES 8192
#define MAX_CONSOLE_RUN 16384

typedef struct {
    int mode; /* 0: inactive, 1: Win32 console, 2: ANSI stream */
    HANDLE input;
    HANDLE output;
    HANDLE alternate;
    DWORD input_mode;
    WORD attributes;
} terminal_state;

static terminal_state terminal = {0};
static int cleanup_registered = 0;

static uint64_t filetime_value(FILETIME value) {
    return ((uint64_t)value.dwHighDateTime << 32) | value.dwLowDateTime;
}

static int windows_version(OSVERSIONINFOEXW *version) {
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    typedef LONG (WINAPI *rtl_get_version_function)(OSVERSIONINFOW *);
    rtl_get_version_function rtl_version = ntdll
        ? (rtl_get_version_function)(void *)GetProcAddress(ntdll,
            "RtlGetVersion") : NULL;
    memset(version, 0, sizeof(*version));
    version->dwOSVersionInfoSize = sizeof(*version);
    if (rtl_version && rtl_version((OSVERSIONINFOW *)version) == 0)
        return 1;
    memset(version, 0, sizeof(*version));
    version->dwOSVersionInfoSize = sizeof(*version);
    return GetVersionExW((OSVERSIONINFOW *)version) != 0;
}

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

static int push_windows_error(lua_State *L, const char *operation) {
    DWORD code = GetLastError();
    lua_pushnil(L);
    lua_pushfstring(L, "%s failed (Win32 error %d)", operation, (int)code);
    lua_pushinteger(L, (lua_Integer)code);
    return 3;
}

static void push_utf8(lua_State *L, const WCHAR *source) {
    int length;
    char *buffer;
    if (!source) {
        lua_pushliteral(L, "");
        return;
    }
    length = WideCharToMultiByte(CP_UTF8, 0, source, -1, NULL, 0, NULL, NULL);
    if (length <= 0 || length > 65536) {
        lua_pushliteral(L, "");
        return;
    }
    buffer = (char *)malloc((size_t)length);
    if (!buffer) luaL_error(L, "out of memory converting Windows text");
    if (!WideCharToMultiByte(CP_UTF8, 0, source, -1, buffer, length, NULL, NULL)) {
        free(buffer);
        lua_pushliteral(L, "");
        return;
    }
    lua_pushlstring(L, buffer, (size_t)length - 1);
    free(buffer);
}

static void utf8_field(lua_State *L, const char *name, const WCHAR *value) {
    push_utf8(L, value);
    lua_setfield(L, -2, name);
}

static WCHAR *utf8_path(lua_State *L, int argument) {
    size_t bytes;
    const char *path = luaL_checklstring(L, argument, &bytes);
    int length;
    WCHAR *wide;
    luaL_argcheck(L, bytes > 0 && bytes <= 32760
        && strlen(path) == bytes, argument, "invalid path");
    length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        path, (int)bytes, NULL, 0);
    if (length <= 0) luaL_argerror(L, argument, "path must be UTF-8");
    wide = (WCHAR *)malloc(((size_t)length + 1) * sizeof(WCHAR));
    if (!wide) luaL_error(L, "out of memory converting path");
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        path, (int)bytes, wide, length)) {
        free(wide);
        luaL_argerror(L, argument, "path must be UTF-8");
    }
    wide[length] = 0;
    return wide;
}

static int ansi_stream_available(void) {
    char term[64];
    DWORD length = GetEnvironmentVariableA("TERM", term, sizeof(term));
    char explicit_pty[4];
    DWORD explicit_length = GetEnvironmentVariableA("WTOP_ANSI_PTY",
        explicit_pty, sizeof(explicit_pty));
    if (length == 0 || length >= sizeof(term) || strcmp(term, "dumb") == 0)
        return 0;
    if (explicit_length != 1 || explicit_pty[0] != '1') return 0;
    return GetFileType(GetStdHandle(STD_INPUT_HANDLE)) == FILE_TYPE_PIPE
        && GetFileType(GetStdHandle(STD_OUTPUT_HANDLE)) == FILE_TYPE_PIPE;
}

static void restore_terminal(void) {
    if (terminal.mode == 1) {
        (void)SetConsoleActiveScreenBuffer(terminal.output);
        (void)SetConsoleMode(terminal.input, terminal.input_mode);
        if (terminal.alternate && terminal.alternate != INVALID_HANDLE_VALUE)
            (void)CloseHandle(terminal.alternate);
    }
    memset(&terminal, 0, sizeof(terminal));
}

static int l_terminal_start(lua_State *L) {
    DWORD input_mode, output_mode;
    CONSOLE_SCREEN_BUFFER_INFO original;
    COORD size;
    HANDLE alternate;
    (void)L;
    if (terminal.mode != 0) {
        lua_pushboolean(L, 1);
        return 1;
    }
    terminal.input = GetStdHandle(STD_INPUT_HANDLE);
    terminal.output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (GetConsoleMode(terminal.input, &input_mode)
        && GetConsoleMode(terminal.output, &output_mode)) {
        if (!GetConsoleScreenBufferInfo(terminal.output, &original))
            return push_windows_error(L, "GetConsoleScreenBufferInfo");
        alternate = CreateConsoleScreenBuffer(GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, CONSOLE_TEXTMODE_BUFFER, NULL);
        if (alternate == INVALID_HANDLE_VALUE)
            return push_windows_error(L, "CreateConsoleScreenBuffer");
        size.X = (SHORT)(original.srWindow.Right - original.srWindow.Left + 1);
        size.Y = (SHORT)(original.srWindow.Bottom - original.srWindow.Top + 1);
        if (size.X < 1) size.X = 80;
        if (size.Y < 1) size.Y = 24;
        (void)SetConsoleScreenBufferSize(alternate, size);
        {
            SMALL_RECT window = {0, 0, (SHORT)(size.X - 1), (SHORT)(size.Y - 1)};
            (void)SetConsoleWindowInfo(alternate, TRUE, &window);
        }
        if (!SetConsoleMode(terminal.input,
            (input_mode & ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT
                | ENABLE_PROCESSED_INPUT | ENABLE_MOUSE_INPUT))
                | ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS)) {
            (void)CloseHandle(alternate);
            return push_windows_error(L, "SetConsoleMode");
        }
        if (!SetConsoleActiveScreenBuffer(alternate)) {
            (void)SetConsoleMode(terminal.input, input_mode);
            (void)CloseHandle(alternate);
            return push_windows_error(L, "SetConsoleActiveScreenBuffer");
        }
        terminal.alternate = alternate;
        terminal.input_mode = input_mode;
        terminal.attributes = original.wAttributes;
        terminal.mode = 1;
    } else if (ansi_stream_available()) {
        terminal.mode = 2;
    } else {
        lua_pushnil(L);
        lua_pushliteral(L, "interactive mode needs a console or an ANSI SSH terminal");
        return 2;
    }
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
}

static int l_terminal_stop(lua_State *L) {
    restore_terminal();
    lua_pushboolean(L, 1);
    return 1;
}

static int l_terminal_capabilities(lua_State *L) {
    lua_createtable(L, 0, 6);
    lua_pushboolean(L, terminal.mode == 1);
    lua_setfield(L, -2, "native_presentation");
    if (terminal.mode == 1) {
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "unicode");
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "mouse");
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "bracketed_paste");
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "truecolor");
        integer_field(L, "colors", 16);
    }
    return 1;
}

static int l_terminal_size(lua_State *L) {
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (terminal.mode == 1) {
        if (!GetConsoleScreenBufferInfo(terminal.alternate, &info))
            return push_windows_error(L, "GetConsoleScreenBufferInfo");
        lua_pushinteger(L, info.srWindow.Right - info.srWindow.Left + 1);
        lua_pushinteger(L, info.srWindow.Bottom - info.srWindow.Top + 1);
    } else {
        int columns = 80, rows = 24;
        char buffer[32];
        if (GetEnvironmentVariableA("COLUMNS", buffer, sizeof(buffer)) > 0) {
            int value = atoi(buffer);
            if (value >= 1 && value <= 10000) columns = value;
        }
        if (GetEnvironmentVariableA("LINES", buffer, sizeof(buffer)) > 0) {
            int value = atoi(buffer);
            if (value >= 1 && value <= 10000) rows = value;
        }
        lua_pushinteger(L, columns);
        lua_pushinteger(L, rows);
    }
    return 2;
}

static const char *virtual_key_name(WORD key) {
    switch (key) {
    case VK_UP: return "up";
    case VK_DOWN: return "down";
    case VK_LEFT: return "left";
    case VK_RIGHT: return "right";
    case VK_HOME: return "home";
    case VK_END: return "end";
    case VK_PRIOR: return "pageup";
    case VK_NEXT: return "pagedown";
    case VK_INSERT: return "insert";
    case VK_DELETE: return "delete";
    case VK_RETURN: return "enter";
    case VK_ESCAPE: return "escape";
    case VK_TAB: return "tab";
    case VK_BACK: return "backspace";
    case VK_SPACE: return "space";
    default:
        if (key >= VK_F1 && key <= VK_F12) {
            static const char *names[] = {
                "f1", "f2", "f3", "f4", "f5", "f6",
                "f7", "f8", "f9", "f10", "f11", "f12",
            };
            return names[key - VK_F1];
        }
        return NULL;
    }
}

static int push_console_key(lua_State *L, const KEY_EVENT_RECORD *record) {
    char key_buffer[8];
    WCHAR wide[2];
    const char *name = virtual_key_name(record->wVirtualKeyCode);
    DWORD state = record->dwControlKeyState;
    int ctrl = (state & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0;
    int alt = (state & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0;
    int shift = (state & SHIFT_PRESSED) != 0;
    int text_length = 0;
    if (!name && record->wVirtualKeyCode >= 'A'
        && record->wVirtualKeyCode <= 'Z') {
        key_buffer[0] = (char)('a' + record->wVirtualKeyCode - 'A');
        key_buffer[1] = '\0';
        name = key_buffer;
    }
    if (!name && record->uChar.UnicodeChar >= 32) {
        wide[0] = record->uChar.UnicodeChar;
        wide[1] = 0;
        text_length = WideCharToMultiByte(CP_UTF8, 0, wide, 1,
            key_buffer, sizeof(key_buffer) - 1, NULL, NULL);
        if (text_length > 0) {
            key_buffer[text_length] = '\0';
            name = key_buffer;
        }
    }
    if (!name) return 0;
    lua_createtable(L, 0, 6);
    string_field(L, "type", "key");
    string_field(L, "key", name);
    lua_pushboolean(L, ctrl);
    lua_setfield(L, -2, "ctrl");
    lua_pushboolean(L, alt);
    lua_setfield(L, -2, "alt");
    lua_pushboolean(L, shift);
    lua_setfield(L, -2, "shift");
    if (!ctrl && !alt && record->uChar.UnicodeChar >= 32) {
        if (!text_length) {
            wide[0] = record->uChar.UnicodeChar;
            wide[1] = 0;
            text_length = WideCharToMultiByte(CP_UTF8, 0, wide, 1,
                key_buffer, sizeof(key_buffer) - 1, NULL, NULL);
        }
        if (text_length > 0) {
            lua_pushlstring(L, key_buffer, (size_t)text_length);
            lua_setfield(L, -2, "text");
        }
    }
    return 1;
}

static int l_poll(lua_State *L) {
    DWORD timeout = (DWORD)luaL_optinteger(L, 1, 0);
    DWORD ready, count;
    luaL_argcheck(L, timeout <= 60000, 1, "timeout must be in 0..60000");
    if (terminal.mode == 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "terminal is not active");
        return 2;
    }
    if (terminal.mode == 2) {
        DWORD started = GetTickCount();
        for (;;) {
            DWORD available = 0;
            if (!PeekNamedPipe(terminal.input, NULL, 0, NULL, &available, NULL)) {
                lua_createtable(L, 0, 1);
                lua_pushboolean(L, 1);
                lua_setfield(L, -2, "hangup");
                return 1;
            }
            if (available > 0) {
                char buffer[4096];
                DWORD wanted = available > sizeof(buffer)
                    ? sizeof(buffer) : available;
                if (!ReadFile(terminal.input, buffer, wanted, &count, NULL))
                    return push_windows_error(L, "ReadFile");
                lua_createtable(L, 0, 1);
                if (count > 0) {
                    lua_pushlstring(L, buffer, count);
                    lua_setfield(L, -2, "data");
                } else {
                    lua_pushboolean(L, 1);
                    lua_setfield(L, -2, "hangup");
                }
                return 1;
            }
            if ((DWORD)(GetTickCount() - started) >= timeout) {
                lua_createtable(L, 0, 0);
                return 1;
            }
            Sleep(5);
        }
    }
    ready = WaitForSingleObject(terminal.input, timeout);
    if (ready == WAIT_FAILED) return push_windows_error(L, "WaitForSingleObject");
    lua_createtable(L, 0, 3);
    if (ready == WAIT_TIMEOUT) return 1;
    {
        INPUT_RECORD record;
        if (!ReadConsoleInputW(terminal.input, &record, 1, &count))
            return push_windows_error(L, "ReadConsoleInputW");
        if (count == 0) return 1;
        if (record.EventType == WINDOW_BUFFER_SIZE_EVENT) {
            lua_pushboolean(L, 1);
            lua_setfield(L, -2, "resize");
        } else if (record.EventType == KEY_EVENT && record.Event.KeyEvent.bKeyDown) {
            lua_createtable(L, 1, 0);
            if (push_console_key(L, &record.Event.KeyEvent)) {
                lua_rawseti(L, -2, 1);
                lua_setfield(L, -2, "events");
            } else {
                lua_pop(L, 1);
            }
        }
    }
    return 1;
}

static WORD console_colour(int index) {
    static const WORD colours[16] = {
        0, 4, 2, 6, 1, 5, 3, 7, 8, 12, 10, 14, 9, 13, 11, 15,
    };
    if (index < 0 || index > 15) return 7;
    return colours[index];
}

static int style_colour(lua_State *L, int style, const char *name, int fallback) {
    int result = fallback;
    lua_getfield(L, style, name);
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "index");
        if (lua_isinteger(L, -1)) result = (int)lua_tointeger(L, -1);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return result;
}

static WORD run_attributes(lua_State *L, int run) {
    int foreground = 7, background = 0, reverse = 0, bold = 0;
    lua_getfield(L, run, "style");
    if (lua_istable(L, -1)) {
        foreground = style_colour(L, lua_gettop(L), "fg", 7);
        background = style_colour(L, lua_gettop(L), "bg", 0);
        lua_getfield(L, -1, "reverse");
        reverse = lua_toboolean(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "bold");
        bold = lua_toboolean(L, -1);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    if (foreground >= 0 && foreground < 16) foreground = console_colour(foreground);
    if (background >= 0 && background < 16) background = console_colour(background);
    if (bold) foreground |= FOREGROUND_INTENSITY;
    if (reverse) {
        int swap = foreground;
        foreground = background;
        background = swap;
    }
    return (WORD)((foreground & 15) | ((background & 15) << 4));
}

static int l_terminal_present(lua_State *L) {
    size_t index, length;
    CONSOLE_SCREEN_BUFFER_INFO info;
    DWORD written;
    int full = 0;
    luaL_checktype(L, 1, LUA_TTABLE);
    if (terminal.mode != 1) {
        lua_pushnil(L);
        lua_pushliteral(L, "native presentation requires a Win32 console");
        return 2;
    }
    if (!GetConsoleScreenBufferInfo(terminal.alternate, &info))
        return push_windows_error(L, "GetConsoleScreenBufferInfo");
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "full");
        full = lua_toboolean(L, -1);
        lua_pop(L, 1);
    }
    if (full) {
        COORD start = {info.srWindow.Left, info.srWindow.Top};
        DWORD cells = (DWORD)(info.srWindow.Right - info.srWindow.Left + 1)
            * (DWORD)(info.srWindow.Bottom - info.srWindow.Top + 1);
        if (!FillConsoleOutputCharacterW(terminal.alternate, L' ', cells,
            start, &written)
            || !FillConsoleOutputAttribute(terminal.alternate,
                terminal.attributes, cells, start, &written))
            return push_windows_error(L, "FillConsoleOutput");
    }
    length = lua_rawlen(L, 1);
    for (index = 1; index <= length; ++index) {
        const char *value;
        size_t bytes;
        int x, y, wide_count, cells;
        WORD attributes;
        WCHAR wide[MAX_CONSOLE_RUN];
        COORD position;
        lua_rawgeti(L, 1, (lua_Integer)index);
        luaL_checktype(L, -1, LUA_TTABLE);
        lua_getfield(L, -1, "x");
        x = (int)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "y");
        y = (int)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "cells");
        cells = (int)luaL_checkinteger(L, -1);
        lua_pop(L, 1);
        lua_getfield(L, -1, "text");
        value = luaL_checklstring(L, -1, &bytes);
        if (bytes >= MAX_CONSOLE_RUN) {
            lua_pop(L, 2);
            lua_pushnil(L);
            lua_pushliteral(L, "console run is too large");
            return 2;
        }
        wide_count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            value, (int)bytes, wide, MAX_CONSOLE_RUN);
        if (wide_count <= 0) {
            lua_pop(L, 2);
            return push_windows_error(L, "MultiByteToWideChar");
        }
        lua_pop(L, 1);
        attributes = run_attributes(L, lua_gettop(L));
        position.X = (SHORT)(info.srWindow.Left + x - 1);
        position.Y = (SHORT)(info.srWindow.Top + y - 1);
        if (!WriteConsoleOutputCharacterW(terminal.alternate, wide,
            (DWORD)wide_count, position, &written)
            || !FillConsoleOutputAttribute(terminal.alternate, attributes,
                (DWORD)cells, position, &written)) {
            lua_pop(L, 1);
            return push_windows_error(L, "WriteConsoleOutputCharacterW");
        }
        lua_pop(L, 1);
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_write(lua_State *L) {
    size_t length, offset = 0;
    const char *text = luaL_checklstring(L, 1, &length);
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    while (offset < length) {
        DWORD written = 0;
        DWORD chunk = (DWORD)((length - offset) > 0x7fffffff
            ? 0x7fffffff : length - offset);
        if (!WriteFile(output, text + offset, chunk, &written, NULL)
            || written == 0)
            return push_windows_error(L, "WriteFile");
        offset += written;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_isatty(lua_State *L) {
    int fd = (int)luaL_checkinteger(L, 1);
    HANDLE handle = GetStdHandle(fd == 0 ? STD_INPUT_HANDLE : STD_OUTPUT_HANDLE);
    DWORD mode;
    lua_pushboolean(L, GetConsoleMode(handle, &mode) || ansi_stream_available());
    return 1;
}

static int l_monotonic_ns(lua_State *L) {
    LARGE_INTEGER count, frequency;
    uint64_t seconds, remainder;
    if (!QueryPerformanceCounter(&count) || !QueryPerformanceFrequency(&frequency)
        || frequency.QuadPart <= 0)
        return push_windows_error(L, "QueryPerformanceCounter");
    seconds = (uint64_t)(count.QuadPart / frequency.QuadPart);
    remainder = (uint64_t)(count.QuadPart % frequency.QuadPart);
    lua_pushinteger(L, (lua_Integer)(seconds * 1000000000ULL
        + remainder * 1000000000ULL / (uint64_t)frequency.QuadPart));
    return 1;
}

static int l_realtime_ns(lua_State *L) {
    FILETIME time;
    GetSystemTimeAsFileTime(&time);
    lua_pushinteger(L, (lua_Integer)((filetime_value(time)
        - UNIX_FILETIME_TICKS) * 100ULL));
    return 1;
}

static int l_sleep_ms(lua_State *L) {
    lua_Integer milliseconds = luaL_checkinteger(L, 1);
    luaL_argcheck(L, milliseconds >= 0 && milliseconds <= 60000, 1,
        "sleep must be in 0..60000");
    Sleep((DWORD)milliseconds);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_uname(lua_State *L) {
    OSVERSIONINFOEXW version;
    SYSTEM_INFO system;
    WCHAR hostname[MAX_COMPUTERNAME_LENGTH + 1];
    DWORD host_length = MAX_COMPUTERNAME_LENGTH + 1;
    char release[64];
    const char *machine;
    if (!windows_version(&version))
        return push_windows_error(L, "GetVersionExW");
    {
        HMODULE kernel = GetModuleHandleA("kernel32.dll");
        typedef void (WINAPI *native_system_info_function)(LPSYSTEM_INFO);
        native_system_info_function native_info = kernel
            ? (native_system_info_function)(void *)GetProcAddress(kernel,
                "GetNativeSystemInfo") : NULL;
        if (native_info) native_info(&system);
        else GetSystemInfo(&system);
    }
    machine = system.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64
        ? "x86_64" : system.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_INTEL
        ? "x86" : "unknown";
    snprintf(release, sizeof(release), "%lu.%lu.%lu",
        (unsigned long)version.dwMajorVersion,
        (unsigned long)version.dwMinorVersion,
        (unsigned long)version.dwBuildNumber);
    lua_createtable(L, 0, 5);
    string_field(L, "sysname", "Windows");
    string_field(L, "release", release);
    string_field(L, "version", release);
    string_field(L, "machine", machine);
    if (GetComputerNameW(hostname, &host_length))
        utf8_field(L, "nodename", hostname);
    return 1;
}

static int l_pid(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)GetCurrentProcessId());
    return 1;
}

static int l_uid(lua_State *L) {
    lua_pushnil(L);
    lua_pushnil(L);
    return 2;
}

static int l_is_admin(lua_State *L) {
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
    PSID group = NULL;
    BOOL member = FALSE;
    if (!AllocateAndInitializeSid(&nt, 2,
        SECURITY_BUILTIN_DOMAIN_RID, DOMAIN_ALIAS_RID_ADMINS,
        0, 0, 0, 0, 0, 0, &group))
        return push_windows_error(L, "AllocateAndInitializeSid");
    if (!CheckTokenMembership(NULL, group, &member)) {
        DWORD code = GetLastError();
        FreeSid(group);
        SetLastError(code);
        return push_windows_error(L, "CheckTokenMembership");
    }
    FreeSid(group);
    lua_pushboolean(L, member);
    return 1;
}

static int l_signal_process(lua_State *L) {
    lua_Integer pid_value = luaL_checkinteger(L, 1);
    lua_Integer signal_value = luaL_checkinteger(L, 2);
    lua_Integer expected_start = luaL_checkinteger(L, 3);
    HANDLE process;
    FILETIME created, exited, kernel, user;
    DWORD code;
    luaL_argcheck(L, pid_value > 1 && pid_value <= 2147483647, 1,
        "invalid process ID");
    if (signal_value != 9) {
        lua_pushnil(L);
        lua_pushliteral(L, "this process action is unavailable on Windows");
        return 2;
    }
    luaL_argcheck(L, expected_start >= 0, 3, "invalid process start time");
    process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_TERMINATE,
        FALSE, (DWORD)pid_value);
    if (!process) return push_windows_error(L, "OpenProcess");
    if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) {
        code = GetLastError();
        CloseHandle(process);
        SetLastError(code);
        return push_windows_error(L, "GetProcessTimes");
    }
    if ((lua_Integer)filetime_value(created) != expected_start) {
        CloseHandle(process);
        lua_pushnil(L);
        lua_pushliteral(L, "process identity changed (PID reuse prevented)");
        return 2;
    }
    if (!TerminateProcess(process, 1)) {
        code = GetLastError();
        CloseHandle(process);
        SetLastError(code);
        return push_windows_error(L, "TerminateProcess");
    }
    CloseHandle(process);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_system_constants(lua_State *L) {
    SYSTEM_INFO system;
    GetSystemInfo(&system);
    lua_createtable(L, 0, 2);
    integer_field(L, "clock_ticks_per_second", 100);
    integer_field(L, "page_size_bytes", (lua_Integer)system.dwPageSize);
    return 1;
}

static int l_access(lua_State *L) {
    WCHAR *path = utf8_path(L, 1);
    DWORD attributes = GetFileAttributesW(path);
    free(path);
    lua_pushboolean(L, attributes != INVALID_FILE_ATTRIBUTES);
    return 1;
}

static int l_getenv(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    WCHAR wide_name[128];
    WCHAR *value;
    DWORD length, read;
    int name_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        name, -1, wide_name, (int)(sizeof(wide_name) / sizeof(wide_name[0])));
    luaL_argcheck(L, name_length > 0 && name_length < 128, 1,
        "invalid environment variable name");
    SetLastError(ERROR_SUCCESS);
    length = GetEnvironmentVariableW(wide_name, NULL, 0);
    if (length == 0) {
        lua_pushnil(L);
        return 1;
    }
    value = (WCHAR *)malloc((size_t)length * sizeof(WCHAR));
    if (!value) return luaL_error(L, "out of memory reading environment");
    read = GetEnvironmentVariableW(wide_name, value, length);
    if (read >= length || read == 0) {
        free(value);
        lua_pushnil(L);
        return 1;
    }
    push_utf8(L, value);
    free(value);
    return 1;
}

static int l_readfile(lua_State *L) {
    WCHAR *path = utf8_path(L, 1);
    lua_Integer requested = luaL_optinteger(L, 2, 4 * 1024 * 1024);
    HANDLE file;
    BY_HANDLE_FILE_INFORMATION details;
    char *buffer;
    size_t length = 0, limit;
    luaL_argcheck(L, requested >= 1 && requested <= 64 * 1024 * 1024, 2,
        "limit must be in 1..67108864");
    limit = (size_t)requested;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE
        | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    free(path);
    if (file == INVALID_HANDLE_VALUE) return push_windows_error(L, "CreateFileW");
    if (!GetFileInformationByHandle(file, &details)) {
        DWORD code = GetLastError();
        CloseHandle(file);
        SetLastError(code);
        return push_windows_error(L, "GetFileInformationByHandle");
    }
    if (details.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY
        | FILE_ATTRIBUTE_REPARSE_POINT)) {
        CloseHandle(file);
        SetLastError(ERROR_INVALID_PARAMETER);
        return push_windows_error(L, "readfile_not_regular");
    }
    buffer = (char *)malloc(limit + 1);
    if (!buffer) {
        CloseHandle(file);
        return luaL_error(L, "out of memory reading file");
    }
    while (length <= limit) {
        DWORD count = 0;
        DWORD wanted = (DWORD)((limit + 1 - length) > 16384
            ? 16384 : limit + 1 - length);
        if (!ReadFile(file, buffer + length, wanted, &count, NULL)) {
            DWORD code = GetLastError();
            free(buffer);
            CloseHandle(file);
            SetLastError(code);
            return push_windows_error(L, "ReadFile");
        }
        if (count == 0) break;
        length += count;
    }
    CloseHandle(file);
    if (length > limit) {
        free(buffer);
        SetLastError(ERROR_FILE_TOO_LARGE);
        return push_windows_error(L, "readfile_limit");
    }
    lua_pushlstring(L, buffer, length);
    free(buffer);
    return 1;
}

static int l_listdir(lua_State *L) {
    WCHAR *path = utf8_path(L, 1);
    lua_Integer limit = luaL_optinteger(L, 2, 2147483647);
    size_t path_length = wcslen(path);
    WCHAR *pattern;
    WIN32_FIND_DATAW entry;
    HANDLE search;
    DWORD attributes;
    int index = 1, truncated = 0;
    luaL_argcheck(L, limit >= 1 && limit <= 2147483647, 2,
        "limit must be in 1..INT_MAX");
    attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES
        || !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        free(path);
        if (attributes != INVALID_FILE_ATTRIBUTES) SetLastError(ERROR_DIRECTORY);
        return push_windows_error(L, "GetFileAttributesW");
    }
    pattern = (WCHAR *)malloc((path_length + 3) * sizeof(WCHAR));
    if (!pattern) {
        free(path);
        return luaL_error(L, "out of memory listing directory");
    }
    wcscpy(pattern, path);
    if (path_length && pattern[path_length - 1] != L'/'
        && pattern[path_length - 1] != L'\\') pattern[path_length++] = L'\\';
    pattern[path_length++] = L'*';
    pattern[path_length] = 0;
    free(path);
    search = FindFirstFileW(pattern, &entry);
    free(pattern);
    if (search == INVALID_HANDLE_VALUE && GetLastError() != ERROR_FILE_NOT_FOUND)
        return push_windows_error(L, "FindFirstFileW");
    lua_createtable(L, 32, 0);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(entry.cFileName, L".") == 0
                || wcscmp(entry.cFileName, L"..") == 0) continue;
            if (index > limit) { truncated = 1; break; }
            push_utf8(L, entry.cFileName);
            lua_rawseti(L, -2, index++);
        } while (FindNextFileW(search, &entry));
        FindClose(search);
    }
    lua_pushnil(L);
    lua_pushboolean(L, truncated);
    return 3;
}

static int l_path_type(lua_State *L) {
    WCHAR *path = utf8_path(L, 1);
    DWORD attributes = GetFileAttributesW(path);
    free(path);
    if (attributes == INVALID_FILE_ATTRIBUTES)
        return push_windows_error(L, "GetFileAttributesW");
    lua_pushstring(L, attributes & FILE_ATTRIBUTE_REPARSE_POINT ? "symlink"
        : attributes & FILE_ATTRIBUTE_DIRECTORY ? "directory" : "regular");
    return 1;
}

static int l_mkdir(lua_State *L) {
    WCHAR *path = utf8_path(L, 1);
    DWORD attributes;
    (void)luaL_optinteger(L, 2, 0700);
    if (CreateDirectoryW(path, NULL)) {
        free(path);
        lua_pushboolean(L, 1);
        return 1;
    }
    attributes = GetFileAttributesW(path);
    free(path);
    if (attributes != INVALID_FILE_ATTRIBUTES
        && attributes & FILE_ATTRIBUTE_DIRECTORY) {
        lua_pushboolean(L, 1);
        return 1;
    }
    return push_windows_error(L, "CreateDirectoryW");
}

static int l_atomic_write(lua_State *L) {
    static unsigned long counter = 0;
    WCHAR *path = utf8_path(L, 1);
    size_t length, offset = 0;
    const char *data = luaL_checklstring(L, 2, &length);
    size_t path_length = wcslen(path);
    WCHAR *temporary = (WCHAR *)malloc((path_length + 80) * sizeof(WCHAR));
    HANDLE file = INVALID_HANDLE_VALUE;
    DWORD code;
    (void)luaL_optinteger(L, 3, 0600);
    if (!temporary) {
        free(path);
        return luaL_error(L, "out of memory writing file");
    }
    for (int attempt = 0; attempt < 100; ++attempt) {
        swprintf(temporary, path_length + 80, L"%ls.wtop-tmp-%lu-%lu",
            path, (unsigned long)GetCurrentProcessId(), ++counter);
        file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL, NULL);
        if (file != INVALID_HANDLE_VALUE || GetLastError() != ERROR_FILE_EXISTS)
            break;
    }
    if (file == INVALID_HANDLE_VALUE) goto failed;
    while (offset < length) {
        DWORD written = 0;
        DWORD wanted = (DWORD)((length - offset) > 65536 ? 65536 : length - offset);
        if (!WriteFile(file, data + offset, wanted, &written, NULL) || written == 0)
            goto failed;
        offset += written;
    }
    if (!FlushFileBuffers(file)) goto failed;
    if (!CloseHandle(file)) {
        file = INVALID_HANDLE_VALUE;
        goto failed;
    }
    file = INVALID_HANDLE_VALUE;
    if (!MoveFileExW(temporary, path,
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) goto failed;
    free(temporary);
    free(path);
    lua_pushboolean(L, 1);
    return 1;
failed:
    code = GetLastError();
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    DeleteFileW(temporary);
    free(temporary);
    free(path);
    SetLastError(code);
    return push_windows_error(L, "atomic_write");
}

static int l_wcwidth(lua_State *L) {
    lua_Integer codepoint = luaL_checkinteger(L, 1);
    if (codepoint < 0 || codepoint > 0x10ffff) {
        lua_pushinteger(L, -1);
    } else if (codepoint == 0) {
        lua_pushinteger(L, 0);
    } else if (codepoint < 32 || (codepoint >= 127 && codepoint < 160)) {
        lua_pushinteger(L, -1);
    } else if (codepoint >= 0x1100 && codepoint <= 0xFF60) {
        lua_pushinteger(L, 2);
    } else {
        lua_pushinteger(L, 1);
    }
    return 1;
}

typedef struct {
    LARGE_INTEGER idle_time;
    LARGE_INTEGER kernel_time;
    LARGE_INTEGER user_time;
    LARGE_INTEGER dpc_time;
    LARGE_INTEGER interrupt_time;
    ULONG interrupt_count;
} processor_performance;

static ULONG query_processor_times(processor_performance *values,
    ULONG capacity) {
    typedef LONG (WINAPI *query_system_information_function)(
        ULONG, PVOID, ULONG, PULONG);
    ULONG returned = 0;
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    query_system_information_function query = ntdll
        ? (query_system_information_function)(void *)GetProcAddress(ntdll,
            "NtQuerySystemInformation") : NULL;
    ULONG bytes = capacity * (ULONG)sizeof(values[0]);
    if (!query || query(8, values, bytes, &returned) < 0
        || returned == 0 || returned > bytes
        || returned % sizeof(values[0]) != 0) return 0;
    return returned / (ULONG)sizeof(values[0]);
}

static int l_collect_cpu(lua_State *L) {
    FILETIME idle_time, kernel_time, user_time;
    uint64_t idle, kernel, user;
    processor_performance processors[256];
    ULONG processor_count = query_processor_times(processors, 256);
    HMODULE system_kernel = GetModuleHandleA("kernel32.dll");
    typedef BOOL (WINAPI *get_system_times_function)(
        LPFILETIME, LPFILETIME, LPFILETIME);
    get_system_times_function get_system_times = system_kernel
        ? (get_system_times_function)(void *)GetProcAddress(system_kernel,
            "GetSystemTimes") : NULL;
    if (get_system_times) {
        if (!get_system_times(&idle_time, &kernel_time, &user_time))
            return push_windows_error(L, "GetSystemTimes");
        idle = filetime_value(idle_time);
        kernel = filetime_value(kernel_time);
        user = filetime_value(user_time);
    } else {
        /* XP before SP1 has no GetSystemTimes export. NT's processor
         * performance query supplies the same cumulative time fields. */
        if (processor_count == 0) {
            lua_pushnil(L);
            lua_pushliteral(L, "system CPU counters are unavailable");
            return 2;
        }
        idle = kernel = user = 0;
        for (ULONG index = 0; index < processor_count; ++index) {
            idle += (uint64_t)processors[index].idle_time.QuadPart;
            kernel += (uint64_t)processors[index].kernel_time.QuadPart;
            user += (uint64_t)processors[index].user_time.QuadPart;
        }
    }
    if (kernel < idle) {
        lua_pushnil(L);
        lua_pushliteral(L, "invalid system CPU counters");
        return 2;
    }
    lua_createtable(L, 0, 2);
    lua_createtable(L, 0, 2);
    integer_field(L, "busy", (lua_Integer)(kernel - idle + user));
    integer_field(L, "total", (lua_Integer)(kernel + user));
    lua_setfield(L, -2, "raw");
    lua_createtable(L, (int)processor_count, 0);
    for (ULONG index = 0; index < processor_count; ++index) {
        uint64_t core_idle = (uint64_t)processors[index].idle_time.QuadPart;
        uint64_t core_kernel = (uint64_t)processors[index].kernel_time.QuadPart;
        uint64_t core_user = (uint64_t)processors[index].user_time.QuadPart;
        if (core_kernel < core_idle) continue;
        lua_createtable(L, 0, 2);
        lua_pushfstring(L, "cpu%d", (int)index);
        lua_setfield(L, -2, "name");
        lua_createtable(L, 0, 2);
        integer_field(L, "busy", (lua_Integer)(core_kernel - core_idle + core_user));
        integer_field(L, "total", (lua_Integer)(core_kernel + core_user));
        lua_setfield(L, -2, "raw");
        lua_rawseti(L, -2, (lua_Integer)index + 1);
    }
    lua_setfield(L, -2, "cores");
    return 1;
}

static int l_collect_cpu_info(lua_State *L) {
    SYSTEM_INFO system;
    GetSystemInfo(&system);
    lua_createtable(L, 0, 1);
    lua_createtable(L, 0, 1);
    integer_field(L, "threads", (lua_Integer)system.dwNumberOfProcessors);
    lua_setfield(L, -2, "topology");
    return 1;
}

static void memory_segment(lua_State *L, int index, const char *id,
    uint64_t bytes) {
    lua_createtable(L, 0, 2);
    string_field(L, "id", id);
    integer_field(L, "bytes", (lua_Integer)bytes);
    lua_rawseti(L, -2, index);
}

static int l_collect_memory(lua_State *L) {
    MEMORYSTATUSEX memory;
    uint64_t swap_total, swap_free, used;
    memset(&memory, 0, sizeof(memory));
    memory.dwLength = sizeof(memory);
    if (!GlobalMemoryStatusEx(&memory))
        return push_windows_error(L, "GlobalMemoryStatusEx");
    used = memory.ullTotalPhys >= memory.ullAvailPhys
        ? memory.ullTotalPhys - memory.ullAvailPhys : 0;
    swap_total = memory.ullTotalPageFile > memory.ullTotalPhys
        ? memory.ullTotalPageFile - memory.ullTotalPhys : 0;
    swap_free = memory.ullAvailPageFile > memory.ullAvailPhys
        ? memory.ullAvailPageFile - memory.ullAvailPhys : 0;
    if (swap_free > swap_total) swap_free = swap_total;
    lua_createtable(L, 0, 10);
    integer_field(L, "total_bytes", (lua_Integer)memory.ullTotalPhys);
    integer_field(L, "available_bytes", (lua_Integer)memory.ullAvailPhys);
    integer_field(L, "used_bytes", (lua_Integer)used);
    integer_field(L, "free_bytes", (lua_Integer)memory.ullAvailPhys);
    integer_field(L, "swap_total_bytes", (lua_Integer)swap_total);
    integer_field(L, "swap_free_bytes", (lua_Integer)swap_free);
    integer_field(L, "swap_used_bytes", (lua_Integer)(swap_total - swap_free));
    lua_createtable(L, 2, 0);
    memory_segment(L, 1, "used", used);
    memory_segment(L, 2, "free", memory.ullAvailPhys);
    lua_setfield(L, -2, "segments");
    return 1;
}

static int l_collect_process(lua_State *L) {
    DWORD pids[MAX_PROCESSES];
    DWORD bytes = 0;
    DWORD count, index, output_index = 1;
    if (!EnumProcesses(pids, sizeof(pids), &bytes))
        return push_windows_error(L, "EnumProcesses");
    count = bytes / sizeof(DWORD);
    lua_createtable(L, 0, 4);
    lua_createtable(L, (int)count, 0);
    for (index = 0; index < count; ++index) {
        DWORD pid = pids[index];
        HANDLE process;
        FILETIME created, exited, kernel, user;
        PROCESS_MEMORY_COUNTERS memory;
        WCHAR name[MAX_PATH];
        int has_times, has_memory;
        char fallback_name[32];
        char fallback_id[48];
        if (!pid) continue;
        process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
            FALSE, pid);
        if (!process)
            process = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, pid);
        if (!process) continue;
        has_times = GetProcessTimes(process, &created, &exited, &kernel, &user);
        memset(&memory, 0, sizeof(memory));
        memory.cb = sizeof(memory);
        has_memory = GetProcessMemoryInfo(process, &memory, sizeof(memory));
        if (!GetModuleBaseNameW(process, NULL, name, MAX_PATH)) {
            DWORD name_length = GetProcessImageFileNameW(process, name, MAX_PATH);
            if (name_length > 0) {
                const WCHAR *base = wcsrchr(name, L'\\');
                if (base && base[1]) {
                    size_t remaining = wcslen(base + 1);
                    memmove(name, base + 1, (remaining + 1) * sizeof(WCHAR));
                }
            } else {
                name[0] = 0;
            }
        }
        (void)CloseHandle(process);
        snprintf(fallback_name, sizeof(fallback_name), "PID %lu",
            (unsigned long)pid);
        snprintf(fallback_id, sizeof(fallback_id), "pid:%lu",
            (unsigned long)pid);
        lua_createtable(L, 0, 9);
        integer_field(L, "pid", (lua_Integer)pid);
        if (name[0]) utf8_field(L, "name", name);
        else string_field(L, "name", fallback_name);
        if (has_times) {
            uint64_t start = filetime_value(created);
            char identity[64];
            snprintf(identity, sizeof(identity), "%lu:%llu",
                (unsigned long)pid, (unsigned long long)start);
            string_field(L, "id", identity);
            integer_field(L, "starttime_ticks", (lua_Integer)start);
            integer_field(L, "cpu_ticks", (lua_Integer)(
                (filetime_value(kernel) + filetime_value(user)) / 100000ULL));
        } else {
            string_field(L, "id", fallback_id);
        }
        if (has_memory) {
            integer_field(L, "resident_bytes", (lua_Integer)memory.WorkingSetSize);
            integer_field(L, "virtual_bytes", (lua_Integer)memory.PagefileUsage);
        }
        lua_rawseti(L, -2, output_index++);
    }
    lua_setfield(L, -2, "list");
    integer_field(L, "process_candidates", (lua_Integer)count);
    integer_field(L, "process_limit", MAX_PROCESSES);
    integer_field(L, "clock_ticks_per_second", 100);
    lua_pushboolean(L, count == MAX_PROCESSES);
    lua_setfield(L, -2, "truncated");
    return 1;
}

static int push_drive_records(lua_State *L, int mounts) {
    WCHAR drives[512];
    DWORD length = GetLogicalDriveStringsW(
        (DWORD)(sizeof(drives) / sizeof(drives[0])), drives);
    int output_index = 1;
    const WCHAR *path;
    if (length == 0 || length >= sizeof(drives) / sizeof(drives[0]))
        return 0;
    lua_createtable(L, 0, 1);
    lua_createtable(L, 16, 0);
    for (path = drives; *path; path += wcslen(path) + 1) {
        ULARGE_INTEGER free_to_user, total, free_total;
        WCHAR filesystem[MAX_PATH];
        DWORD flags = 0;
        UINT kind = GetDriveTypeW(path);
        uint64_t used;
        if (kind == DRIVE_REMOTE || kind == DRIVE_NO_ROOT_DIR) continue;
        if (!GetDiskFreeSpaceExW(path, &free_to_user, &total, &free_total))
            continue;
        if (total.QuadPart == 0) continue;
        used = total.QuadPart >= free_total.QuadPart
            ? total.QuadPart - free_total.QuadPart : 0;
        lua_createtable(L, 0, 8);
        if (mounts) {
            utf8_field(L, "id", path);
            utf8_field(L, "mount_point", path);
            utf8_field(L, "source", path);
            string_field(L, "kind", kind == DRIVE_REMOTE ? "network" : "local");
            if (GetVolumeInformationW(path, NULL, 0, NULL, NULL,
                &flags, filesystem, MAX_PATH)) {
                utf8_field(L, "fs_type", filesystem);
                lua_pushboolean(L, (flags & FILE_READ_ONLY_VOLUME) != 0);
                lua_setfield(L, -2, "readonly");
            }
            lua_createtable(L, 0, 4);
            integer_field(L, "total_bytes", (lua_Integer)total.QuadPart);
            integer_field(L, "available_bytes",
                (lua_Integer)free_to_user.QuadPart);
            integer_field(L, "used_bytes", (lua_Integer)used);
            number_field(L, "used_percent",
                (lua_Number)used * 100 / (lua_Number)total.QuadPart);
            lua_setfield(L, -2, "capacity");
        } else {
            utf8_field(L, "name", path);
            lua_createtable(L, 0, 2);
            integer_field(L, "size_bytes", (lua_Integer)total.QuadPart);
            lua_setfield(L, -2, "identity");
        }
        lua_rawseti(L, -2, output_index++);
    }
    lua_setfield(L, -2, mounts ? "mounts" : "devices");
    return 1;
}

static int l_collect_disk(lua_State *L) {
    if (!push_drive_records(L, 0))
        return push_windows_error(L, "GetLogicalDriveStringsW");
    return 1;
}

static int l_collect_mounts(lua_State *L) {
    if (!push_drive_records(L, 1))
        return push_windows_error(L, "GetLogicalDriveStringsW");
    return 1;
}

static int l_collect_network(lua_State *L) {
    ULONG size = 0;
    DWORD status = GetIfTable(NULL, &size, FALSE);
    MIB_IFTABLE *interfaces;
    DWORD index, output_index = 1;
    if (status != ERROR_INSUFFICIENT_BUFFER || size == 0 || size > 1024 * 1024) {
        lua_pushnil(L);
        lua_pushliteral(L, "GetIfTable failed or returned too much data");
        return 2;
    }
    interfaces = (MIB_IFTABLE *)malloc(size);
    if (!interfaces) return luaL_error(L, "out of memory collecting interfaces");
    status = GetIfTable(interfaces, &size, FALSE);
    if (status != NO_ERROR) {
        free(interfaces);
        lua_pushnil(L);
        lua_pushfstring(L, "GetIfTable failed (Win32 error %d)", (int)status);
        return 2;
    }
    lua_createtable(L, 0, 1);
    lua_createtable(L, (int)interfaces->dwNumEntries, 0);
    for (index = 0; index < interfaces->dwNumEntries; ++index) {
        MIB_IFROW *entry = &interfaces->table[index];
        WCHAR name[MAX_INTERFACE_NAME_LEN];
        size_t copy_bytes = sizeof(name) < sizeof(entry->wszName)
            ? sizeof(name) : sizeof(entry->wszName);
        memcpy(name, entry->wszName, copy_bytes);
        name[MAX_INTERFACE_NAME_LEN - 1] = 0;
        lua_createtable(L, 0, 9);
        integer_field(L, "id", (lua_Integer)entry->dwIndex);
        utf8_field(L, "name", name);
        string_field(L, "operstate",
            entry->dwOperStatus == IF_OPER_STATUS_OPERATIONAL ? "up" : "down");
        integer_field(L, "mtu", (lua_Integer)entry->dwMtu);
        number_field(L, "speed_mbps", (lua_Number)entry->dwSpeed / 1000000.0);
        lua_createtable(L, 0, 4);
        integer_field(L, "rx_bytes", (lua_Integer)entry->dwInOctets);
        integer_field(L, "tx_bytes", (lua_Integer)entry->dwOutOctets);
        integer_field(L, "rx_errors", (lua_Integer)entry->dwInErrors);
        integer_field(L, "tx_errors", (lua_Integer)entry->dwOutErrors);
        lua_setfield(L, -2, "counters");
        lua_rawseti(L, -2, output_index++);
    }
    free(interfaces);
    lua_setfield(L, -2, "interfaces");
    return 1;
}

static int l_collect_system_info(lua_State *L) {
    OSVERSIONINFOEXW version;
    SYSTEM_INFO system;
    WCHAR hostname[MAX_COMPUTERNAME_LENGTH + 1];
    DWORD host_length = MAX_COMPUTERNAME_LENGTH + 1;
    char release[64], pretty[96];
    HMODULE kernel;
    typedef ULONGLONG (WINAPI *tick64_function)(void);
    tick64_function tick64;
    uint64_t uptime = 0;
    if (!windows_version(&version))
        return push_windows_error(L, "GetVersionExW");
    {
        HMODULE system_kernel = GetModuleHandleA("kernel32.dll");
        typedef void (WINAPI *native_system_info_function)(LPSYSTEM_INFO);
        native_system_info_function native_info = system_kernel
            ? (native_system_info_function)(void *)GetProcAddress(system_kernel,
                "GetNativeSystemInfo") : NULL;
        if (native_info) native_info(&system);
        else GetSystemInfo(&system);
    }
    snprintf(release, sizeof(release), "%lu.%lu.%lu",
        (unsigned long)version.dwMajorVersion,
        (unsigned long)version.dwMinorVersion,
        (unsigned long)version.dwBuildNumber);
    snprintf(pretty, sizeof(pretty), "Windows NT %s", release);
    kernel = GetModuleHandleA("kernel32.dll");
    tick64 = kernel ? (tick64_function)(void *)GetProcAddress(kernel,
        "GetTickCount64") : NULL;
    if (tick64) uptime = (uint64_t)tick64() / 1000ULL;
    lua_createtable(L, 0, 5);
    lua_createtable(L, 0, 2);
    if (GetComputerNameW(hostname, &host_length))
        utf8_field(L, "hostname", hostname);
    string_field(L, "architecture",
        system.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64
            ? "x86_64" : system.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_INTEL
            ? "x86" : "unknown");
    lua_setfield(L, -2, "host");
    lua_createtable(L, 0, 3);
    string_field(L, "name", "Windows");
    string_field(L, "pretty_name", pretty);
    string_field(L, "version", release);
    lua_setfield(L, -2, "distribution");
    lua_createtable(L, 0, 3);
    string_field(L, "type", "Windows NT");
    string_field(L, "release", release);
    string_field(L, "version", release);
    lua_setfield(L, -2, "kernel");
    if (tick64) number_field(L, "uptime_seconds", (lua_Number)uptime);
    return 1;
}

static const luaL_Reg functions[] = {
    {"terminal_start", l_terminal_start},
    {"terminal_stop", l_terminal_stop},
    {"terminal_capabilities", l_terminal_capabilities},
    {"terminal_size", l_terminal_size},
    {"terminal_present", l_terminal_present},
    {"poll", l_poll},
    {"write", l_write},
    {"isatty", l_isatty},
    {"monotonic_ns", l_monotonic_ns},
    {"realtime_ns", l_realtime_ns},
    {"sleep_ms", l_sleep_ms},
    {"uname", l_uname},
    {"pid", l_pid},
    {"uid", l_uid},
    {"is_admin", l_is_admin},
    {"signal_process", l_signal_process},
    {"system_constants", l_system_constants},
    {"access", l_access},
    {"getenv", l_getenv},
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

int __declspec(dllexport) luaopen_wtop_native(lua_State *L) {
    luaL_newlib(L, functions);
    string_field(L, "VERSION", "win32-0.1");
    return 1;
}
