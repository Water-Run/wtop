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
 *   key:<text>         type each character (\e Escape, \r Enter, ^c Ctrl+C)
 *   vk:<code>          press one virtual key (decimal), e.g. 40 for Down
 *   snap:<label>       print the visible window of the active screen buffer
 *   resize:<cols>x<rows>  resize the active buffer and its window
 *   exit:<ms>          wait for the program to exit and print its exit code
 */
#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
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

static void snapshot(const char *label) {
    HANDLE output = console_output();
    CONSOLE_SCREEN_BUFFER_INFO info;
    CHAR_INFO *cells;
    COORD size, origin = {0, 0};
    SMALL_RECT region;
    int columns, rows, distinct = 0;
    WORD seen[64];
    if (output == INVALID_HANDLE_VALUE || !GetConsoleScreenBufferInfo(output, &info)) {
        printf("===== %s: screen buffer unavailable (error %lu)\n", label,
            (unsigned long)GetLastError());
        if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
        return;
    }
    columns = info.srWindow.Right - info.srWindow.Left + 1;
    rows = info.srWindow.Bottom - info.srWindow.Top + 1;
    size.X = (SHORT)columns;
    size.Y = (SHORT)rows;
    region = info.srWindow;
    cells = (CHAR_INFO *)calloc((size_t)columns * (size_t)rows, sizeof(CHAR_INFO));
    /* Read bytes rather than UTF-16: in a double-byte code page the legacy
     * console returns one UTF-16 unit for a two-cell character, which shifts
     * every later cell. Bytes map one to one onto cells. */
    if (!cells || !ReadConsoleOutputA(output, cells, size, origin, &region)) {
        printf("===== %s: read failed (error %lu)\n", label, (unsigned long)GetLastError());
        free(cells);
        CloseHandle(output);
        return;
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

int main(int argc, char **argv) {
    STARTUPINFOW start;
    PROCESS_INFORMATION process;
    WCHAR command[4096];
    char *steps, *step;
    int length = 0;
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
        else if (strcmp(step, "key") == 0) type_text(value);
        else if (strcmp(step, "vk") == 0) press_virtual_key(atoi(value));
        else if (strcmp(step, "snap") == 0) snapshot(value);
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
    return 0;
}
