/* Drive wtop inside a real Win32 console without a desktop session.
 *
 * The harness allocates its own console, starts the program on it, and then
 * reads the active screen buffer, injects key events, and
 * resizes the buffer the way a person at a classic CMD window would. It is a
 * validation tool for the native console backend, not part of the bundle.
 *
 * usage: console_harness.exe STEPS COMMAND...
 * STEPS is a comma list of:
 *   wait:<ms>          sleep
 *   await:<ms>:<text>  wait for visible ASCII text, fail on timeout
 *   key:<text>         type each character (\e Escape, \r Enter, ^c Ctrl+C)
 *   vk:<code>          press one virtual key (decimal), e.g. 40 for Down
 *   snap:<label>       print the visible window of the active screen buffer
 *   resize:<cols>x<rows>  resize the active buffer and its window
 *   cpu:<ms>            measure child CPU use while waiting
 *   exit:<ms>          wait for the program to exit and print its exit code
 * WTOP_TEST_CONSOLE_CODEPAGE optionally selects the new console's code page.
 */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HANDLE console_input(void) {
    return CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
}

static HANDLE console_output(void) {
    return CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
}

static void print_utf8(const WCHAR *text, int count) {
    char buffer[4096];
    int length = WideCharToMultiByte(CP_UTF8, 0, text, count, buffer,
        (int)sizeof(buffer) - 1, NULL, NULL);
    if (length > 0) fwrite(buffer, 1, (size_t)length, stdout);
}

static int snapshot_if(const char *label, const char *required) {
    HANDLE output = console_output();
    CONSOLE_SCREEN_BUFFER_INFO info;
    CHAR_INFO *cells;
    COORD size, origin = {0, 0};
    SMALL_RECT region;
    int columns, rows, distinct = 0;
    WORD seen[64];
    if (output == INVALID_HANDLE_VALUE || !GetConsoleScreenBufferInfo(output, &info)) {
        if (!required) printf("===== %s: screen buffer unavailable (error %lu)\n", label,
            (unsigned long)GetLastError());
        if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
        return 0;
    }
    columns = info.srWindow.Right - info.srWindow.Left + 1;
    rows = info.srWindow.Bottom - info.srWindow.Top + 1;
    if (columns <= 0 || columns > 1023 || rows <= 0
            || (size_t)columns * (size_t)rows > 200000) { CloseHandle(output); return 0; }
    size.X = (SHORT)columns;
    size.Y = (SHORT)rows;
    region = info.srWindow;
    cells = (CHAR_INFO *)calloc((size_t)columns * (size_t)rows, sizeof(CHAR_INFO));
    /* Read bytes rather than UTF-16: in a double-byte code page the legacy
     * console returns one UTF-16 unit for a two-cell character, which shifts
     * every later cell. Bytes map one to one onto cells. */
    if (!cells || !ReadConsoleOutputA(output, cells, size, origin, &region)) {
        if (!required) printf("===== %s: read failed (error %lu)\n", label, (unsigned long)GetLastError());
        free(cells);
        CloseHandle(output);
        return 0;
    }
    if (required) {
        size_t capacity = (size_t)rows * ((size_t)columns + 1) + 1, used = 0;
        char *visible = malloc(capacity);
        int matches = visible != NULL;
        if (visible) {
            for (int y = 0; y < rows; ++y) {
                for (int x = 0; x < columns; ++x) {
                    char value = cells[y * columns + x].Char.AsciiChar;
                    visible[used++] = value ? value : ' ';
                }
                visible[used++] = '\n';
            }
            visible[used] = 0;
            const char *start = required;
            while (*start && matches) {
                const char *separator = strchr(start, '|');
                size_t length = separator ? (size_t)(separator - start) : strlen(start);
                char marker[128];
                if (!length || length >= sizeof(marker)) { matches = 0; break; }
                memcpy(marker, start, length); marker[length] = 0;
                if (!strstr(visible, marker)) matches = 0;
                if (!separator) break;
                start = separator + 1;
            }
        }
        free(visible);
        if (!matches) { free(cells); CloseHandle(output); return 0; }
    }
    printf("===== %s (%dx%d, buffer %dx%d, cursor %d,%d)\n", label, columns, rows,
        info.dwSize.X, info.dwSize.Y, info.dwCursorPosition.X, info.dwCursorPosition.Y);
    for (int y = 0; y < rows; ++y) {
        char bytes[1024];
        WCHAR line[1024];
        int count = 0, length;
        for (int x = 0; x < columns && count < 1023; ++x) {
            const CHAR_INFO *cell = &cells[y * columns + x];
            int known = 0;
            bytes[count++] = cell->Char.AsciiChar ? cell->Char.AsciiChar : ' ';
            for (int index = 0; index < distinct; ++index)
                if (seen[index] == (cell->Attributes & 0xff)) known = 1;
            if (!known && distinct < 64) seen[distinct++] = (WORD)(cell->Attributes & 0xff);
        }
        length = MultiByteToWideChar(GetConsoleOutputCP(), 0, bytes, count, line, 1023);
        while (length > 0 && line[length - 1] == L' ') --length;
        print_utf8(line, length);
        putchar('\n');
    }
    printf("----- %d distinct colour attributes\n", distinct);
    fflush(stdout);
    free(cells);
    CloseHandle(output);
    return 1;
}

static void snapshot(const char *label) { (void)snapshot_if(label, NULL); }

static int capture_when(const char *label, const char *required, DWORD timeout) {
    DWORD started = GetTickCount();
    if (!required[0] || !timeout || timeout > 60000) return 0;
    do {
        /* Validate and print the same captured cells. A repaint between a
         * separate readiness poll and screenshot must not create an empty frame. */
        if (snapshot_if(label, required)) return 1;
        Sleep(50);
    } while (GetTickCount() - started < timeout);
    printf("----- timed out capturing %s: %s\n", label, required);
    return 0;
}

static int wait_for_text(const char *text, DWORD timeout) {
    DWORD started = GetTickCount();
    if (!text[0] || timeout == 0 || timeout > 60000) return 0;
    do {
        HANDLE output = console_output();
        CONSOLE_SCREEN_BUFFER_INFO info;
        int found = 0;
        if (output != INVALID_HANDLE_VALUE && GetConsoleScreenBufferInfo(output, &info)) {
            int columns = info.srWindow.Right - info.srWindow.Left + 1;
            int rows = info.srWindow.Bottom - info.srWindow.Top + 1;
            size_t count = (size_t)columns * (size_t)rows;
            if (columns > 0 && rows > 0 && count <= 200000) {
                CHAR_INFO *cells = (CHAR_INFO *)calloc(count, sizeof(CHAR_INFO));
                char *visible = (char *)malloc(count + (size_t)rows + 1);
                COORD size = {(SHORT)columns, (SHORT)rows}, origin = {0, 0};
                SMALL_RECT region = info.srWindow;
                if (cells && visible && ReadConsoleOutputA(output, cells, size, origin, &region)) {
                    size_t used = 0;
                    for (int row = 0; row < rows; ++row) {
                        for (int column = 0; column < columns; ++column) {
                            char value = cells[row * columns + column].Char.AsciiChar;
                            visible[used++] = value ? value : ' ';
                        }
                        visible[used++] = '\n';
                    }
                    visible[used] = 0;
                    found = strstr(visible, text) != NULL;
                }
                free(cells);
                free(visible);
            }
        }
        if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
        if (found) {
            printf("----- observed: %s\n", text);
            fflush(stdout);
            return 1;
        }
        Sleep(50);
    } while (GetTickCount() - started < timeout);
    printf("----- timed out waiting for: %s\n", text);
    fflush(stdout);
    return 0;
}

static void send_key(HANDLE input, WORD virtual_key, WCHAR character, DWORD state) {
    INPUT_RECORD records[2];
    DWORD written;
    memset(records, 0, sizeof(records));
    for (int index = 0; index < 2; ++index) {
        records[index].EventType = KEY_EVENT;
        records[index].Event.KeyEvent.bKeyDown = index == 0;
        records[index].Event.KeyEvent.wRepeatCount = 1;
        records[index].Event.KeyEvent.wVirtualKeyCode = virtual_key;
        records[index].Event.KeyEvent.wVirtualScanCode =
            (WORD)MapVirtualKeyW(virtual_key, 0);
        records[index].Event.KeyEvent.uChar.UnicodeChar = character;
        records[index].Event.KeyEvent.dwControlKeyState = state;
    }
    WriteConsoleInputW(input, records, 2, &written);
}

static void type_text(const char *text) {
    HANDLE input = console_input();
    if (input == INVALID_HANDLE_VALUE) return;
    for (const char *p = text; *p; ++p) {
        if (p[0] == '\\' && p[1] == 'e') { send_key(input, VK_ESCAPE, 27, 0); ++p; }
        else if (p[0] == '\\' && p[1] == 'r') { send_key(input, VK_RETURN, 13, 0); ++p; }
        else if (p[0] == '^' && p[1]) {
            char letter = (char)(p[1] & ~0x20);
            send_key(input, (WORD)letter, (WCHAR)(letter - 'A' + 1), LEFT_CTRL_PRESSED);
            ++p;
        } else {
            SHORT scan = VkKeyScanA(*p);
            DWORD state = (scan >> 8) & 1 ? SHIFT_PRESSED : 0;
            send_key(input, (WORD)(scan & 0xff), (WCHAR)(unsigned char)*p, state);
        }
        Sleep(60);
    }
    CloseHandle(input);
}

static void press_virtual_key(int code) {
    HANDLE input = console_input();
    if (input == INVALID_HANDLE_VALUE) return;
    send_key(input, (WORD)code, 0, 0);
    CloseHandle(input);
}

static void resize(int columns, int rows) {
    HANDLE output = console_output();
    CONSOLE_SCREEN_BUFFER_INFO info;
    COORD size;
    SMALL_RECT window = {0, 0, (SHORT)(columns - 1), (SHORT)(rows - 1)};
    BOOL buffer_ok, window_ok;
    if (output == INVALID_HANDLE_VALUE) return;
    GetConsoleScreenBufferInfo(output, &info);
    size.X = (SHORT)columns;
    size.Y = (SHORT)rows;
    /* Grow the buffer before the window and shrink the window before the
     * buffer, as the console requires. */
    if (columns >= info.dwSize.X && rows >= info.dwSize.Y) {
        buffer_ok = SetConsoleScreenBufferSize(output, size);
        window_ok = SetConsoleWindowInfo(output, TRUE, &window);
    } else {
        window_ok = SetConsoleWindowInfo(output, TRUE, &window);
        buffer_ok = SetConsoleScreenBufferSize(output, size);
    }
    printf("----- resize %dx%d buffer=%d window=%d (error %lu)\n", columns, rows,
        buffer_ok, window_ok, (unsigned long)GetLastError());
    fflush(stdout);
    CloseHandle(output);
}

static uint64_t filetime_ticks(FILETIME time) {
    return ((uint64_t)time.dwHighDateTime << 32) | time.dwLowDateTime;
}

static void sample_cpu(HANDLE child, DWORD duration_ms) {
    FILETIME created, exited, kernel_before, user_before, kernel_after, user_after;
    DWORD started, elapsed;
    uint64_t before, after;
    if (duration_ms == 0 || duration_ms > 60000
        || WaitForSingleObject(child, 0) != WAIT_TIMEOUT
        || !GetProcessTimes(child, &created, &exited,
            &kernel_before, &user_before)) {
        printf("----- cpu sample unavailable (child not running or invalid interval)\n");
        fflush(stdout);
        return;
    }
    started = GetTickCount();
    Sleep(duration_ms);
    elapsed = GetTickCount() - started;
    if (elapsed == 0 || WaitForSingleObject(child, 0) != WAIT_TIMEOUT
        || !GetProcessTimes(child, &created, &exited,
            &kernel_after, &user_after)) {
        printf("----- cpu sample unavailable (child exited)\n");
        fflush(stdout);
        return;
    }
    before = filetime_ticks(kernel_before) + filetime_ticks(user_before);
    after = filetime_ticks(kernel_after) + filetime_ticks(user_after);
    if (after < before) {
        printf("----- cpu sample unavailable (counter reset)\n");
        fflush(stdout);
        return;
    }
    printf("----- cpu over %lu ms: %.2f ms, %.2f%% of one core\n",
        (unsigned long)elapsed, (double)(after - before) / 10000.0,
        (double)(after - before) / ((double)elapsed * 100.0));
    fflush(stdout);
}

int main(int argc, char **argv) {
    STARTUPINFOW start;
    PROCESS_INFORMATION process;
    WCHAR command[4096];
    char *steps, *step;
    int length = 0, failed = 0;
    if (argc < 3) {
        fprintf(stderr, "usage: console_harness STEPS COMMAND...\n");
        return 2;
    }
    command[0] = 0;
    for (int index = 2; index < argc; ++index) {
        length += MultiByteToWideChar(CP_UTF8, 0, argv[index], -1, command + length,
            (int)(sizeof(command) / sizeof(command[0])) - length - 2) - 1;
        if (index + 1 < argc) command[length++] = L' ';
        command[length] = 0;
    }
    /* Own a fresh console and hand its handles to the child explicitly. A
     * service-hosted parent (Cygwin sshd) has pipes as standard handles, and
     * those would otherwise leak into the child instead of the console. */
    FreeConsole();
    if (!AllocConsole()) {
        printf("AllocConsole failed (error %lu)\n", (unsigned long)GetLastError());
        return 4;
    }
    {
        const char *value = getenv("WTOP_TEST_CONSOLE_CODEPAGE");
        if (value && value[0]) {
            char *end;
            unsigned long page = strtoul(value, &end, 10);
            if (*end || !page || page > 65535
                    || !SetConsoleCP((UINT)page) || !SetConsoleOutputCP((UINT)page)) {
                printf("cannot set the test console code page (error %lu)\n",
                    (unsigned long)GetLastError());
                return 4;
            }
        }
    }
    {
        SECURITY_ATTRIBUTES inherit = {sizeof(inherit), NULL, TRUE};
        HANDLE input = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, NULL);
        HANDLE output = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, NULL);
        CONSOLE_SCREEN_BUFFER_INFO info;
        COORD size = {80, 25};
        SMALL_RECT window = {0, 0, 79, 24};
        if (input == INVALID_HANDLE_VALUE || output == INVALID_HANDLE_VALUE) {
            printf("console handles unavailable (error %lu)\n", (unsigned long)GetLastError());
            return 4;
        }
        /* A classic CMD window: 80x25 visible, as on a default install. */
        if (GetConsoleScreenBufferInfo(output, &info)) {
            SetConsoleWindowInfo(output, TRUE, &window);
            SetConsoleScreenBufferSize(output, size);
        }
        memset(&start, 0, sizeof(start));
        start.cb = sizeof(start);
        start.dwFlags = STARTF_USESTDHANDLES;
        start.hStdInput = input;
        start.hStdOutput = output;
        start.hStdError = output;
        if (!CreateProcessW(NULL, command, NULL, NULL, TRUE, 0, NULL, NULL,
            &start, &process)) {
            printf("CreateProcess failed (error %lu)\n", (unsigned long)GetLastError());
            return 3;
        }
        CloseHandle(input);
        CloseHandle(output);
    }
    printf("sharing a console with PID %lu, code page %u\n",
        (unsigned long)process.dwProcessId, GetConsoleOutputCP());
    fflush(stdout);
    steps = strdup(argv[1]);
    for (step = strtok(steps, ","); step; step = strtok(NULL, ",")) {
        char *value = strchr(step, ':');
        if (!value) continue;
        *value++ = 0;
        if (strcmp(step, "wait") == 0) Sleep((DWORD)atoi(value));
        else if (strcmp(step, "await") == 0) {
            char *text = strchr(value, ':');
            if (!text) failed = 1;
            else {
                *text++ = 0;
                if (!wait_for_text(text, (DWORD)atoi(value))) failed = 1;
            }
        }
        else if (strcmp(step, "key") == 0) type_text(value);
        else if (strcmp(step, "vk") == 0) press_virtual_key(atoi(value));
        else if (strcmp(step, "snap") == 0) snapshot(value);
        else if (strcmp(step, "capture") == 0) {
            char *label = strchr(value, ':'), *required = label ? strchr(label + 1, ':') : NULL;
            if (!label || !required) failed = 1;
            else {
                *label++ = 0; *required++ = 0;
                if (!capture_when(label, required, (DWORD)atoi(value))) failed = 1;
            }
        }
        else if (strcmp(step, "cpu") == 0) sample_cpu(process.hProcess,
            (DWORD)atoi(value));
        else if (strcmp(step, "resize") == 0) {
            int columns = 0, rows = 0;
            if (sscanf(value, "%dx%d", &columns, &rows) == 2) resize(columns, rows);
        } else if (strcmp(step, "exit") == 0) {
            DWORD code = 259;
            DWORD waited = WaitForSingleObject(process.hProcess, (DWORD)atoi(value));
            GetExitCodeProcess(process.hProcess, &code);
            printf("----- process %s, exit code %lu\n",
                waited == WAIT_OBJECT_0 ? "exited" : "still running", (unsigned long)code);
            fflush(stdout);
        }
    }
    free(steps);
    if (WaitForSingleObject(process.hProcess, 0) != WAIT_OBJECT_0) {
        TerminateProcess(process.hProcess, 1);
        printf("----- terminated a process that did not exit\n");
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return failed ? 1 : 0;
}
