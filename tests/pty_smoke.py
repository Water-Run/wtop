#!/usr/bin/env python3
"""Exercise the real raw-terminal loop across the responsive size matrix."""

from __future__ import annotations

import fcntl
import os
import pathlib
import pty
import re
import select
import signal
import stat
import struct
import tempfile
import termios
import time
import unicodedata


ROOT = pathlib.Path(os.environ.get("WTOP_ROOT", pathlib.Path(__file__).resolve().parents[1]))
LUA = os.environ.get("WTOP_LUA", str(ROOT / ".tools/lua-5.5.1/bin/lua"))
EXECUTABLE = os.environ.get("WTOP_EXECUTABLE")
SIZES = (
    (60, 20),
    (80, 50),
    (40, 10),
    (80, 24),
    (80, 25),
    (160, 24),
    (200, 22),
    (180, 45),
)
EDIT_MARKERS = (b"LAYOUT", "布局".encode())
SEARCH_MARKERS = (b"Search", "搜索".encode())
PROCESS_DETAIL_MARKERS = (b"Process details", "进程详情".encode())
PAGE_MARKERS = {
    1: ("CPU", "内存", "温度"),
    2: ("进程 - CPU 降序",),
    3: ("逻辑 CPU", "频率策略"),
    4: ("块设备", "文件系统与挂载点"),
    5: ("网络接口", "套接字与连接"),
    6: ("图形设备", "GPU 进程"),
    7: ("cgroup v2 工作负载",),
    8: ("能力与检查器",),
}


class VirtualScreen:
    """Small VT screen model for the exact ANSI subset emitted by wtop."""

    def __init__(self, columns: int, rows: int) -> None:
        self.columns = columns
        self.rows = rows
        self.characters = [[" " for _ in range(columns)] for _ in range(rows)]
        self.painted = [[False for _ in range(columns)] for _ in range(rows)]
        self.x = 0
        self.y = 0
        self.autowrap = True
        self.pending_wrap = False

    def _clear(self) -> None:
        self.characters = [
            [" " for _ in range(self.columns)] for _ in range(self.rows)
        ]
        self.painted = [
            [False for _ in range(self.columns)] for _ in range(self.rows)
        ]
        self.x = self.y = 0
        self.pending_wrap = False

    @staticmethod
    def _width(character: str) -> int:
        if character in ("\u200d", "\ufe0e", "\ufe0f") or unicodedata.combining(character):
            return 0
        return 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1

    def _write(self, character: str) -> None:
        width = self._width(character)
        if width == 0:
            if self.x > 0 and 0 <= self.y < self.rows:
                self.characters[self.y][self.x - 1] += character
            return
        if self.pending_wrap:
            if self.autowrap:
                self.x, self.y = 0, self.y + 1
            self.pending_wrap = False
        if self.y >= self.rows:
            return
        if width == 2 and self.x >= self.columns - 1:
            return
        if self.x >= self.columns:
            self.x = self.columns - 1
        self.characters[self.y][self.x] = character
        self.painted[self.y][self.x] = True
        if width == 2:
            self.characters[self.y][self.x + 1] = ""
            self.painted[self.y][self.x + 1] = True
        if self.x + width >= self.columns:
            self.x = self.columns - 1
            self.pending_wrap = True
        else:
            self.x += width

    def _csi(self, raw_parameters: str, final: str) -> None:
        if final in ("H", "f"):
            values = raw_parameters.split(";") if raw_parameters else []
            row = int(values[0] or "1") if values else 1
            column = int(values[1] or "1") if len(values) > 1 else 1
            self.y = max(0, min(self.rows - 1, row - 1))
            self.x = max(0, min(self.columns - 1, column - 1))
            self.pending_wrap = False
        elif final == "J" and (raw_parameters or "0") == "2":
            self._clear()
        elif final == "l" and raw_parameters == "?7":
            self.autowrap = False
            self.pending_wrap = False
        elif final == "h" and raw_parameters == "?7":
            self.autowrap = True
            self.pending_wrap = False

    def feed(self, output: bytes) -> None:
        position = 0
        while position < len(output):
            if output[position : position + 2] == b"\x1b[":
                end = position + 2
                while end < len(output) and not 0x40 <= output[end] <= 0x7E:
                    end += 1
                if end >= len(output):
                    break
                parameters = output[position + 2 : end].decode("ascii", "ignore")
                self._csi(parameters, chr(output[end]))
                position = end + 1
                continue
            if output[position] == 0x1B:
                position += min(2, len(output) - position)
                continue
            end = output.find(b"\x1b", position)
            if end < 0:
                end = len(output)
            for character in output[position:end].decode("utf-8", "replace"):
                if character == "\r":
                    self.x = 0
                    self.pending_wrap = False
                elif character == "\n":
                    self.y += 1
                    self.pending_wrap = False
                elif ord(character) >= 0x20 and character != "\x7f":
                    self._write(character)
            position = end

    def text(self) -> str:
        return "\n".join("".join(row) for row in self.characters)

    def unpainted(self) -> int:
        return sum(not cell for row in self.painted for cell in row)


def _assert_complete_screen(
    output: bytes, columns: int, rows: int, forbidden: tuple[str, ...] = ()
) -> None:
    screen = VirtualScreen(columns, rows)
    screen.feed(output)
    assert screen.unpainted() == 0, (
        f"final {columns}x{rows} terminal screen has {screen.unpainted()} cells "
        "that were never painted"
    )
    text = screen.text()
    assert text.startswith("wtop"), "final terminal screen lost the application header"
    for marker in forbidden:
        assert marker not in text, f"final terminal screen retained stale content: {marker}"


def _assert_persisted_layout(config_home: pathlib.Path) -> None:
    layout = config_home / "wtop" / "layout.yml"
    assert layout.is_file(), f"layout editor did not persist {layout}"
    mode = stat.S_IMODE(layout.stat().st_mode)
    assert mode == 0o600, f"layout permissions are {mode:#05o}, expected 0o600"

    contents = layout.read_text(encoding="utf-8")
    assert "schema_version: 2\n" in contents, "layout has no supported schema version"
    assert "pages:\n" in contents, "layout has no pages mapping"
    assert "  overview:\n" in contents, "layout has no overview workspace"
    # The exercise starts focused on cpu_overview and moves it one place right.
    # Checking the serialized order proves that the arrow key changed real
    # workspace state rather than merely opening and closing edit mode.
    memory_position = contents.find('widget_id: "memory_overview"')
    cpu_position = contents.find('widget_id: "cpu_overview"')
    assert 0 <= memory_position < cpu_position, (
        "overview widget move was not persisted:\n" + contents
    )
    assert "ratio_micros: 550000" in contents, (
        "overview split ratio edit/redo was not persisted:\n" + contents
    )


def _run_session(
    columns: int,
    rows: int,
    exercise: bool,
    config_home: pathlib.Path,
    delay_reader: bool = False,
    page_switch: bool = False,
    final_page: int | None = None,
    frequency_click: bool = False,
    terminal_environment: dict[str, str | None] | None = None,
    cli_options: tuple[str, ...] = (),
) -> bytes:
    pid, master = pty.fork()
    if pid == 0:
        environment = os.environ.copy()
        if EXECUTABLE:
            environment["LUA_PATH"] = ""
            environment["LUA_CPATH"] = ""
        else:
            environment["LUA_PATH"] = f"{ROOT}/src/?.lua;{ROOT}/src/?/init.lua;;"
            environment["LUA_CPATH"] = f"{ROOT}/build/native/?.so;;"
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        # The host running the tests may intentionally prefer monochrome.
        # Test profiles must be hermetic so their names match the code paths
        # they actually exercise.
        environment.pop("NO_COLOR", None)
        for name, value in (terminal_environment or {}).items():
            if value is None:
                environment.pop(name, None)
            else:
                environment[name] = value
        environment["XDG_CONFIG_HOME"] = str(config_home)
        arguments = ["--interval", "300"]
        if "--lang" not in cli_options:
            arguments.extend(("--lang", "zh-CN"))
        arguments.extend(cli_options)
        if EXECUTABLE:
            os.execve(EXECUTABLE, [EXECUTABLE, *arguments], environment)
        os.execve(LUA, [LUA, str(ROOT / "src/wtop.lua"), *arguments], environment)

    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
    if delay_reader:
        # A large truecolor frame exceeds a typical PTY queue. Historically,
        # terminal_start accidentally made stdout non-blocking through the
        # shared PTY open-file description; the write then stopped around row
        # 25 and the renderer silently recorded that partial frame as complete.
        # Holding the reader back makes that production failure deterministic.
        time.sleep(0.75)
    os.set_blocking(master, False)
    output = bytearray()
    deadline = time.monotonic() + 8.0
    # None is a live TIOCSWINSZ/SIGWINCH transition from narrow-tall to
    # wide-short; byte entries are terminal input.
    if exercise:
        actions = [
            b"e", b"\x1b[C", b"]", b"u", b"U", b"e", None,
            b"2", b"/", "测试".encode(), b"\x7f", b"\r", b"\x1b",
            b"o", b"t", b"\x1b[B", b"\r", b"\x1b[6~", b"\x1b", b"q",
        ]
    elif page_switch:
        actions = [b"2", b"3", b"6", b"1", b"q"]
    elif final_page is not None:
        assert final_page in PAGE_MARKERS
        actions = [str(final_page).encode("ascii"), b"q"]
    elif frequency_click:
        click_x = max(1, columns - 2)
        actions = [
            f"\x1b[<0;{click_x};1M".encode("ascii"),
            f"\x1b[<0;{click_x};1m".encode("ascii"),
            b"q",
        ]
    else:
        actions = [b"q"]
    action_delay = 0.2 if exercise or page_switch or final_page is not None or frequency_click else 0.0
    action_index = 0
    next_action_at = None
    status = None
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except BlockingIOError:
                    chunk = b""
                except OSError:
                    chunk = b""
                output.extend(chunk)
            now = time.monotonic()
            if next_action_at is None and (
                b"wtop" in output or now > deadline - 5.0
            ):
                # Seeing the brand proves startup sampling has completed and the
                # input/render loop is active; the time fallback keeps failures
                # bounded enough to produce useful child diagnostics.
                next_action_at = now + action_delay
            if (
                next_action_at is not None
                and action_index < len(actions)
                and now >= next_action_at
                and (
                    not exercise
                    or action_index != 1
                    or any(marker in output for marker in EDIT_MARKERS)
                )
            ):
                action = actions[action_index]
                if action is None:
                    fcntl.ioctl(
                        master,
                        termios.TIOCSWINSZ,
                        struct.pack("HHHH", 24, 160, 0, 0),
                    )
                    os.kill(pid, signal.SIGWINCH)
                else:
                    os.write(master, action)
                action_index += 1
                # Separate edit, move, finish and quit across poll/render turns.
                next_action_at = now + action_delay
            waited, wait_status = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                status = wait_status
                break
        if status is None:
            os.kill(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
            raise AssertionError(f"wtop PTY session {columns}x{rows} timed out")
    finally:
        os.close(master)

    assert os.WIFEXITED(status), f"wtop {columns}x{rows} terminated abnormally: {status}"
    assert os.WEXITSTATUS(status) == 0, (
        f"wtop {columns}x{rows} exited {os.WEXITSTATUS(status)}\n"
        + output[-4000:].decode("utf-8", "replace")
    )
    assert b"\x1b[?1049h" in output, f"wtop {columns}x{rows} did not enter alternate screen"
    assert b"\x1b[?1049l" in output, f"wtop {columns}x{rows} did not restore alternate screen"
    assert b"wtop" in output, f"wtop {columns}x{rows} rendered no application frame"
    if delay_reader:
        addressed_rows = {
            int(value) for value in re.findall(rb"\x1b\[(\d+);\d+H", output)
        }
        assert rows in addressed_rows, (
            f"wtop {columns}x{rows} only delivered rows through "
            f"{max(addressed_rows or {0})} under PTY backpressure"
        )
    if not exercise:
        forbidden = ("进程 - CPU 降序", "逻辑 CPU", "GPU 进程", "图形设备") \
            if page_switch else ()
        _assert_complete_screen(bytes(output), columns, rows, forbidden)
        if page_switch:
            final_text = VirtualScreen(columns, rows)
            final_text.feed(bytes(output))
            final_screen = final_text.text()
            # Brackets are the active-tab cue in monochrome only. Assert
            # overview-specific cards so this check works in every colour
            # depth and cannot pass merely because the tab label is visible.
            assert all(marker in final_screen for marker in ("CPU", "内存", "温度")), (
                "page-switch sequence did not end on overview"
            )
        if final_page is not None:
            final_text = VirtualScreen(columns, rows)
            final_text.feed(bytes(output))
            final_screen = final_text.text()
            assert all(marker in final_screen for marker in PAGE_MARKERS[final_page]), (
                f"page {final_page} final screen lacks its semantic markers"
            )
        if frequency_click:
            final_text = VirtualScreen(columns, rows)
            final_text.feed(bytes(output))
            assert "更新频率：中高" in final_text.text(), (
                "top-right click did not advance the update frequency from 中 to 中高"
            )
    if exercise:
        assert action_index == len(actions), "layout exercise did not send every action"
        assert any(marker in output for marker in EDIT_MARKERS), (
            "overview layout edit mode was not rendered"
        )
        assert any(marker in output for marker in SEARCH_MARKERS), (
            "process search editor was not rendered"
        )
        assert "测".encode() in output, "UTF-8 process query/backspace was not rendered"
        assert any(marker in output for marker in PROCESS_DETAIL_MARKERS), (
            "process detail overlay was not rendered"
        )
        _assert_persisted_layout(config_home)
    return bytes(output)


def run_session(
    columns: int,
    rows: int,
    exercise: bool,
    delay_reader: bool = False,
    page_switch: bool = False,
    final_page: int | None = None,
    frequency_click: bool = False,
    terminal_environment: dict[str, str | None] | None = None,
    cli_options: tuple[str, ...] = (),
) -> bytes:
    # Every PTY case receives a unique XDG root. This protects the developer's
    # real layout even when a smoke test crashes midway and also prevents cases
    # from depending on the persisted order from an earlier size.
    with tempfile.TemporaryDirectory(prefix="wtop-pty-xdg-") as temporary:
        return _run_session(
            columns,
            rows,
            exercise,
            pathlib.Path(temporary),
            delay_reader,
            page_switch,
            final_page,
            frequency_click,
            terminal_environment,
            cli_options,
        )


def main() -> None:
    captures = []
    for index, (columns, rows) in enumerate(SIZES):
        captures.append(
            run_session(
                columns,
                rows,
                exercise=index == 1,
                delay_reader=index == len(SIZES) - 1,
            )
        )
        print(f"PTY {columns}x{rows}: ok")
    captures.append(run_session(200, 45, exercise=False, page_switch=True))
    print("PTY 200x45 page-switch final screen: ok")
    for page in range(2, 9):
        captures.append(run_session(180, 45, exercise=False, final_page=page))
        print(f"PTY 180x45 page {page} final screen: ok")

    captures.append(
        run_session(
            100,
            30,
            exercise=False,
            frequency_click=True,
            cli_options=("--interval", "1000"),
        )
    )
    print("PTY 100x30 top-right frequency click: ok")

    # Exercise the colour and character-width fallbacks through the real
    # terminal adapter. These profiles catch styling code that only works in a
    # GNOME/xterm truecolour UTF-8 environment.
    colour256 = run_session(
        100,
        30,
        exercise=False,
        terminal_environment={"TERM": "screen-256color", "COLORTERM": None},
        cli_options=("--theme", "water-light", "--lang", "en-US"),
    )
    assert re.search(rb"(?:38|48);5;\d+", colour256), "256-colour profile emitted no indexed colours"
    assert b";2;" not in colour256, "256-colour profile leaked truecolour SGR"
    print("PTY 100x30 256-colour/light theme: ok")

    colour16 = run_session(
        100,
        30,
        exercise=False,
        terminal_environment={"TERM": "xterm", "COLORTERM": None},
        cli_options=("--theme", "colorblind", "--lang", "en-US"),
    )
    assert b";2;" not in colour16 and not re.search(rb"(?:38|48);5;\d+", colour16), (
        "16-colour profile emitted a higher colour depth"
    )
    print("PTY 100x30 16-colour/colorblind theme: ok")

    high_contrast = run_session(
        100,
        30,
        exercise=False,
        cli_options=("--theme", "high-contrast", "--lang", "en-US"),
    )
    assert re.search(rb"(?:38|48);2;\d+;\d+;\d+", high_contrast), (
        "truecolour/high-contrast profile emitted no RGB colours"
    )
    print("PTY 100x30 truecolour/high-contrast theme: ok")

    ascii_mono = run_session(
        100,
        30,
        exercise=False,
        terminal_environment={
            "TERM": "dumb",
            "COLORTERM": None,
            "LC_ALL": "C",
            "LC_CTYPE": "C",
            "LANG": "C",
        },
        cli_options=("--no-color", "--lang", "en-US"),
    )
    assert all(value < 128 for value in ascii_mono), (
        "ASCII terminal profile received non-ASCII bytes"
    )
    assert b";2;" not in ascii_mono and not re.search(rb"(?:38|48);5;\d+", ascii_mono), (
        "no-colour profile emitted coloured SGR"
    )
    print("PTY 100x30 ASCII/no-colour profile: ok")
    assert any("进程".encode() in capture or "概览".encode() in capture for capture in captures), (
        "zh-CN catalog was not visible in any PTY frame"
    )


if __name__ == "__main__":
    main()
