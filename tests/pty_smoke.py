#!/usr/bin/env python3
"""Exercise the real raw-terminal loop across the responsive size matrix."""

from __future__ import annotations

import fcntl
import os
import pathlib
import pty
import sys
import re
import select
import shlex
import shutil
import random
import signal
import subprocess
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
# The thread-row column header of the process detail overlay; untranslated by
# design, so a single marker covers every locale.
PROCESS_THREAD_MARKERS = (b"TID",)
# The heading of the *thread* detail overlay, as opposed to the process one.  It
# is the gate the thread-drilldown scenario needs for its resize: the renderer
# repaints only the cells that changed, so a repaint that lands before an
# overlay is open rewrites the page instead and the overlay's action line is
# never written as a whole line -- see `run_thread_drilldown`.
# The status line echoes an applied filter, so its marker proves the query was
# accepted by the real search editor rather than dropped.  The numeric term's
# interpretation is covered by the unit tests; what matters here is that the
# terminal path carries a comparison through without breaking the table.
PROCESS_FILTER_MARKERS = (b"Filter:", "过滤：".encode())
# Inspector navigation is the same for every inspector: enumerate, then either
# pick an entity or read the reason there is nothing to pick.  Both branches
# carry the inspector's own title, so one marker per inspector covers them.
SMART_PICKER_MARKERS = (b"SMART / NVMe", "SMART / NVMe".encode())
BANDWIDTH_MARKERS = (b"RAM bandwidth", "RAM 带宽".encode())
SIGNAL_MARKERS = (b"SIGTERM", "发送信号".encode())
# The layout palette picker that "a" and "r" open while editing a layout.
WIDGET_PICKER_MARKERS = (b"Add widget", "添加组件".encode())
WIDGET_REPLACE_MARKERS = (b"Replace widget", "替换组件".encode())
HELP_MARKERS = (b"Navigation", "导航".encode())
# The workspace manager's New row is rendered by the overlay alone, so seeing
# it proves the list is on screen rather than merely open; the rename hint and
# the post-rename status line carry the same proof for their own states.  The
# scenarios that use these pin --lang zh-CN, so the markers are zh-CN too.
WORKSPACE_MANAGER_MARKERS = ("新建：".encode(),)
WORKSPACE_RENAME_MARKERS = ("确认重命名".encode(),)
WORKSPACE_RENAMED_MARKERS = ("已重命名为".encode(),)
LUA_BLUE_BACKGROUND = b"48;2;0;0;128"
# Key "0" selects the tenth tab, matching the in-app binding.
PAGE_KEYS = {1: "1", 2: "2", 3: "3", 4: "4", 5: "5", 6: "6", 7: "7", 8: "8", 9: "9", 10: "0"}
PAGE_MARKERS = {
    1: ("CPU", "内存", "主机"),
    2: ("进程", "命令"),
    3: ("逻辑 CPU", "各核心 CPU"),
    4: ("内存构成", "分页与缺页"),
    5: ("块设备", "文件系统与挂载点"),
    6: ("网络接口", "套接字与连接"),
    7: ("图形设备", "GPU 进程"),
    8: ("cgroup v2 工作负载",),
    9: ("主机与操作系统", "内核与启动"),
    10: ("采集器", "深度检查器"),
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


def _screen_at_last_paint(
    output: bytes, markers: tuple[bytes, ...], columns: int, rows: int
) -> list[str]:
    """Replay only the prefix of the stream that ends with the last paint of the
    latest-painted marker in `markers`, and return the reconstructed screen as a
    list of stripped rows.

    A session can only be closed with `q`, so the *final* frame of a case that
    drilled into an overlay is the bare table with the overlay already gone --
    reconstructing the whole stream therefore never shows the overlay at all.
    Cutting the stream at the last paint of a marker inside the overlay recovers
    the frame the operator was actually looking at.

    Several markers are offered because the overlay does not repaint uniformly:
    the rows that tick are rewritten every frame and the ones that do not are
    left alone, so the last paint of any single row is a frame boundary only by
    accident.  Taking the latest of several picks the boundary that is actually
    the end of the overlay's last frame, which is what puts the rows above *and*
    below the anchor on the same reconstructed screen.

    This is also the only way to assert on a *row* rather than on the byte
    stream.  The renderer paints a label and its value in separate cells with
    SGR attributes between them, so two labels that share a word are
    indistinguishable in the raw bytes but not once the screen is rebuilt.
    """
    cut, length = -1, 0
    for marker in markers:
        index = output.rfind(marker)
        if index > cut:
            cut, length = index, len(marker)
    assert cut >= 0, f"the stream never painted any of {markers!r}"
    screen = VirtualScreen(columns, rows)
    screen.feed(output[: cut + length])
    return [row.strip() for row in screen.text().split("\n")]


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
    script: list[tuple[object, object]] | None = None,
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
    # The interactive exercise now drives thirty-odd bindings at 0.2 s apart,
    # so the budget scales with the script instead of being a fixed eight
    # seconds that silently became too small as coverage grew.
    deadline = time.monotonic() + 8.0
    # None is a live TIOCSWINSZ/SIGWINCH transition from narrow-tall to
    # wide-short; byte entries are terminal input.
    if script is not None:
        actions = script
    elif exercise:
        # Each entry is (input, required_markers).  Gating by what must already
        # be on screen keeps the script reorderable; the previous version
        # gated on a hard-coded action index, so inserting a binding silently
        # made the harness wait for an overlay that had not been opened.
        actions = [
            (b"e", None), (b"\x1b[C", EDIT_MARKERS), (b"]", None), (b"u", None),
            (b"U", None), (b"e", None),
            # Widget editing runs on the Memory page, leaving the Overview move
            # and ratio the persistence check looks at untouched.  It starts by
            # removing the focused widget, because the default layout places
            # every widget a page defines and an empty palette would leave the
            # picker nothing to offer.  A marker gates the action that follows
            # it, so each picker opens unconditionally and the dismissal waits.
            (b"4", None), (b"e", None), (b"d", None), (b"a", None),
            (b"\x1b", WIDGET_PICKER_MARKERS),
            (b"r", None), (b"\r", WIDGET_REPLACE_MARKERS),
            (b"e", None), (b"1", None), (None, None),
            (b"2", None), (b"/", None), ("测试".encode(), None), (b"\x7f", None),
            (b"\r", SEARCH_MARKERS), (b"\x1b", None),
            # A numeric filter, alone and combined with a text term, driven
            # through the real search editor.  The editor opens pre-filled with
            # the current query and the cursor at the end, so each draft is
            # killed to the start before typing rather than appended to.
            (b"/", None), (b"\x17", None), (b"threads>0", None),
            (b"\r", PROCESS_FILTER_MARKERS),
            (b"/", None), (b"\x17", None), (b"user:root threads>0", None),
            (b"\r", PROCESS_FILTER_MARKERS),
            (b"/", None), (b"\x17", None), (b"\r", None),
            # sort forward, reverse, tree, full paths, then keyboard paging
            (b"o", None), (b"O", None), (b"t", None), (b"p", None),
            (b"\x1b[6~", None), (b"\x1b[H", None), (b"\x1b[F", None),
            (b"\x1b[B", None),
            # process details open, scroll and close; the close key is gated on
            # the thread rows having rendered, which proves the detail-mode
            # /proc/<pid>/task scan reached the overlay.  The thread section
            # leads the overlay, so Home brings it back into view after the
            # page-down above; the detail pass lands a tick after the overlay
            # opens, and the close key waits for it.
            (b"\r", None), (b"\x1b[6~", PROCESS_DETAIL_MARKERS),
            (b"\x1b[H", None),
            (b"\x1b", PROCESS_THREAD_MARKERS),
            # the signal menu opens and cancels without sending anything
            (b"k", None), (b"\x1b[B", SIGNAL_MARKERS), (b"\x1b", SIGNAL_MARKERS),
            # inspector navigation: SMART enumerates block devices and offers a
            # picker; RAM bandwidth enumerates memory controllers, which this
            # host may not have, so either the picker or the reason it has none
            # is a correct outcome.  Each key opens unconditionally and the
            # dismissal is what waits for the overlay.
            (b"s", None), (b"\x1b", SMART_PICKER_MARKERS),
            (b"b", None), (b"\x1b", BANDWIDTH_MARKERS),
            # search line editing: type, move the cursor, kill a word, cancel
            (b"/", None), ("user:root sy".encode(), None),
            (b"\x1b[D", None), (b"\x1b[D", None), (b"\x1b[H", None), (b"\x1b[F", None),
            (b"\x17", None), (b"\x1b", None),
            # theme cycle, language cycle, virtual-device toggle, help overlay
            (b"T", None), (b"L", None), (b"L", None), (b"v", None), (b"?", None),
            (b"\x1b[6~", None), (b"\x1b", None),
            (b"q", None),
        ]
    elif page_switch:
        actions = [(key, None) for key in (b"2", b"3", b"6", b"1", b"q")]
    elif final_page is not None:
        assert final_page in PAGE_MARKERS
        actions = [(PAGE_KEYS[final_page].encode("ascii"), None), (b"q", None)]
    elif frequency_click:
        click_x = max(1, columns - 2)
        actions = [
            (f"\x1b[<0;{click_x};1M".encode("ascii"), None),
            (f"\x1b[<0;{click_x};1m".encode("ascii"), None),
            (b"q", None),
        ]
    else:
        actions = [(b"q", None)]
    action_delay = 0.2 if exercise or page_switch or final_page is not None or frequency_click else 0.0
    # A bare Escape is a prefix, not a key: if the next byte reaches the child
    # in the same read, the decoder correctly reports Alt+<key> instead of
    # Escape followed by that key, exactly as xterm does.  Under load the child
    # can be descheduled for longer than the normal gap, batching the two.  So
    # an Escape gets its own, much wider gap rather than relying on the
    # scheduler to keep the writes apart.
    escape_delay = max(action_delay * 4, 0.6)
    budget = sum(
        (action[1] if isinstance(action, tuple) and action[0] == "sleep" else 0.0)
        + (escape_delay if action == b"\x1b" else action_delay)
        for action, _ in actions
    )
    deadline = max(deadline, time.monotonic() + 8.0 + budget * 2.0)
    action_index = 0
    next_action_at = None
    status = None
    # Quitting is the one action whose lateness changes what the assertions see.
    # Every other action is followed by its own turn, and the stream carries the
    # repaint that turn produced; the quit is different, because the child exits
    # on it and a repaint still in flight when it does is never written.  The
    # assertions then read a screen the product had already left -- measured, the
    # 200x45 page-switch check reported a stale panel title and the per-thread
    # drill-down lost its run-queue row, on two different runs, while both passed
    # ten times out of ten on their own.  So the quit waits for the stream to go
    # quiet instead of trusting the fixed gap between actions, with a cap: a busy
    # host refreshes faster than any quiet window and the session must still end.
    settle_quiet = 0.35
    settle_cap = 1.5
    last_output_at = time.monotonic()
    settle_started_at = None
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
                if chunk:
                    last_output_at = time.monotonic()
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
                    # Never act on an overlay before a slower collection or
                    # render turn has actually put it on screen.
                    actions[action_index][1] is None
                    or any(marker in output for marker in actions[action_index][1])
                )
            ):
                action = actions[action_index][0]
                # The settle wait, applied to the quit and to nothing else.
                if action == b"q":
                    if settle_started_at is None:
                        settle_started_at = now
                    quiet_for = now - last_output_at
                    waited_for = now - settle_started_at
                    if quiet_for < settle_quiet and waited_for < settle_cap:
                        continue
                extra_delay = 0.0
                if isinstance(action, tuple) and action[0] == "sleep":
                    # Hold the current view while frames render, then continue.
                    extra_delay = max(0.0, action[1] - action_delay)
                if action is None:
                    fcntl.ioctl(
                        master,
                        termios.TIOCSWINSZ,
                        struct.pack("HHHH", 24, 160, 0, 0),
                    )
                    os.kill(pid, signal.SIGWINCH)
                elif isinstance(action, tuple) and action[0] == "resize":
                    fcntl.ioctl(
                        master,
                        termios.TIOCSWINSZ,
                        struct.pack("HHHH", action[1], action[2], 0, 0),
                    )
                    os.kill(pid, signal.SIGWINCH)
                elif isinstance(action, tuple) and action[0] == "signal":
                    os.kill(pid, action[1])
                elif isinstance(action, tuple) and action[0] == "sleep":
                    pass
                else:
                    os.write(master, action)
                action_index += 1
                # The settle window is per-quit, not per-session: a later quit
                # must not inherit the wait an earlier one already spent.
                if action != b"q":
                    settle_started_at = None
                # Separate edit, move, finish and quit across poll/render turns.
                next_action_at = now + (
                    escape_delay if action == b"\x1b" else action_delay
                ) + extra_delay
            waited, wait_status = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                status = wait_status
                break
        if status is None:
            os.kill(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
            tail = output[-4000:].decode("utf-8", "replace")
            raise AssertionError(
                f"wtop PTY session {columns}x{rows} timed out at action "
                f"{action_index}/{len(actions)}\n{tail}"
            )
        # The child has exited, but the last thing it wrote - the cursor and
        # alternate-screen restore - may still be sitting in the pty buffer.
        # Reaping the child says nothing about the reader having seen it, so
        # drain to EOF rather than racing the kernel for the final bytes.
        drain_deadline = time.monotonic() + 2.0
        while time.monotonic() < drain_deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if not ready:
                break
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
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
        # Page-unique widget text: none of it may survive a switch away.
        forbidden = ("排序：", "逻辑 CPU", "套接字与连接") if page_switch else ()
        _assert_complete_screen(bytes(output), columns, rows, forbidden)
        if page_switch:
            final_text = VirtualScreen(columns, rows)
            final_text.feed(bytes(output))
            final_screen = final_text.text()
            # Brackets are the active-tab cue in monochrome only. Assert
            # overview-specific cards so this check works in every colour
            # depth and cannot pass merely because the tab label is visible.
            # Cards that are always present on overview.  The temperature and
            # GPU cards are deliberately not listed: a host without hwmon or a
            # DRM device now hides them rather than showing an empty frame, so
            # asserting them would make the test host-dependent.
            assert all(marker in final_screen for marker in ("CPU", "内存", "主机")), (
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
        assert any(marker in output for marker in WIDGET_PICKER_MARKERS), (
            "the add-widget palette picker was not rendered"
        )
        assert any(marker in output for marker in WIDGET_REPLACE_MARKERS), (
            "the replace-widget palette picker was not rendered"
        )
        assert any(marker in output for marker in SEARCH_MARKERS), (
            "process search editor was not rendered"
        )
        assert "测".encode() in output, "UTF-8 process query/backspace was not rendered"
        assert any(marker in output for marker in PROCESS_FILTER_MARKERS), (
            "a numeric process filter was not applied"
        )
        assert any(marker in output for marker in SMART_PICKER_MARKERS), (
            "the SMART inspector did not open its entity list"
        )
        assert any(marker in output for marker in BANDWIDTH_MARKERS), (
            "the RAM bandwidth inspector did not open"
        )
        assert any(marker in output for marker in PROCESS_DETAIL_MARKERS), (
            "process detail overlay was not rendered"
        )
        assert any(marker in output for marker in PROCESS_THREAD_MARKERS), (
            "process detail overlay did not render thread rows"
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
    script: list[tuple[object, object]] | None = None,
    config_home: pathlib.Path | None = None,
) -> bytes:
    # Every PTY case receives a unique XDG root. This protects the developer's
    # real layout even when a smoke test crashes midway and also prevents cases
    # from depending on the persisted order from an earlier size.  A case that
    # starts a second session against the same root passes its own path, which
    # is the only way to observe what one session left behind.
    def launch(home: pathlib.Path) -> bytes:
        return _run_session(
            columns,
            rows,
            exercise,
            home,
            delay_reader,
            page_switch,
            final_page,
            frequency_click,
            terminal_environment,
            cli_options,
            script,
        )

    if config_home is not None:
        return launch(config_home)
    with tempfile.TemporaryDirectory(prefix="wtop-pty-xdg-") as temporary:
        return launch(pathlib.Path(temporary))


def run_ascii_profile() -> bytes:
    output = run_session(
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
    assert all(value < 128 for value in output), (
        "ASCII terminal profile received non-ASCII bytes"
    )
    # As above, the truecolour form must be matched precisely so the SGR dim
    # attribute is not mistaken for a colour.
    assert not re.search(rb"(?:38|48);2;\d+;\d+;\d+", output) and not re.search(
        rb"(?:38|48);5;\d+", output
    ), (
        "no-colour profile emitted coloured SGR"
    )
    return output


def run_resize_storm() -> bytes:
    """A continuous resize storm must not crash the loop or corrupt the final
    frame; the settled size renders a complete screen again."""
    walker = random.Random(20260928)
    script: list[tuple[object, object]] = []
    for _ in range(48):
        columns = walker.choice((24, 40, 60, 80, 100, 132, 160, 200))
        rows = walker.choice((8, 10, 16, 24, 30, 40, 50))
        script.append((("resize", rows, columns), None))
    # Settle long enough for several complete frames at the final size, then
    # quit normally so the restore path still runs after the storm.
    script.append((("resize", 24, 80), None))
    script.append((("sleep", 1.5), None))
    script.append((b"q", None))
    # The session starts and settles at the same size so the built-in final
    # screen assertion applies to the post-storm frame.
    return run_session(80, 24, exercise=False, script=script)


def run_gpu_device_frequency() -> None:
    """The GPU table's frequency cell must never read 0 Hz.

    A clock that is powered down is reported by the kernel as 0, and 0 is not a
    frequency -- it is a state.  Lua's `or` treats 0 as a present value, so
    preferring the kernel's "actual" clock with `actual or current` published
    the zero; on the development host, whose integrated GPU sits in RC6 for most
    of every second, the GPU page duly read 0 Hz for a part running at 300 MHz.
    The cell is asserted never to be zero, which is the invariant rather than
    the particular figure: any host, any clock, any state.

    The column is `full_only`, so the terminal has to be wide enough for the
    table to keep it, and a resize forces the complete repaint that puts the
    value on the wire as a whole cell rather than as a scattered digit.

    A host with no GPU at all legitimately has no row to check, and that must
    not fail the matrix.
    """
    out = run_session(240, 40, exercise=False, script=[
        (PAGE_KEYS[7].encode("ascii"), None),   # GPU page
        (("sleep", 1.2), None),
        (("resize", 41, 240), None),           # force a complete repaint
        (("resize", 40, 240), None),
        (("sleep", 0.8), None),
        (b"q", None),
    ])
    screen = VirtualScreen(240, 40)
    screen.feed(out)
    rows = [row.strip() for row in screen.text().split("\n")]
    # The header names the column; without it the width was too small for the
    # table to keep it and there is nothing to assert about.  The match is on a
    # whole cell, not a substring: the top bar carries "更新频率：高" (the update
    # rate), and a substring match finds that first.
    if not any("频率" in row.split() or "Frequency" in row.split() for row in rows):
        return
    # The invariant is stated over the whole page rather than over one cell
    # because the cell cannot be located reliably: a CJK label occupies two
    # screen columns per character, so a character offset taken from the header
    # does not address the same columns in the data row, and every cell value
    # that contains a space ("300 MHz") splits into more tokens than the header
    # has columns.  A zero-frequency cell needs no such addressing to be
    # unambiguous -- frequency is the only figure on this page carrying Hz,
    # beside a percent, a byte count, a temperature, watts and RPM.
    for row in rows:
        assert "0 Hz" not in row, (
            "the GPU table reported a clock at 0 Hz, which is a powered-down "
            "state rather than a frequency:\n" + row
        )


def run_gpu_client_drilldown() -> None:
    """The GPU process row is an aggregate; `i` must show what it aggregates.

    A host PID can hold several DRM clients, and the table sums them into one
    row, so the breakdown is the only place an operator learns which client and
    which memory region is responsible.  A process with one client goes straight
    to its detail; several get the list, `Enter` opens one, and `Esc` steps back
    out of it before it closes.

    The overlay is asserted on the raw stream because a host with no GPU at all
    legitimately shows nothing to drill into, and that must not fail the matrix.
    The engine names are the kernel's own (`render`, `video`) and are not
    translated, so they are matched as they appear in `/proc/<pid>/fdinfo`.
    """
    script: list[tuple[object, object]] = [
        (PAGE_KEYS[7].encode("ascii"), None),
        (("sleep", 1.0), None),
        (b"i", None),
        (("sleep", 1.5), None),
    ]
    out = run_session(160, 45, exercise=False, script=script + [
        (b"\r", None),                   # into the client, or a no-op on a detail
        (("sleep", 1.2), None),
        (b"\x1b", None),                 # back out one level
        (("sleep", 1.0), None),
        (b"\x1b", None),                 # and close
        (("sleep", 0.6), None),
        (b"q", None),                    # quit
    ])
    if not any(
        marker.encode() in out
        for marker in ("客户端", "Engines", "引擎", " Engines", "Motores", "Moteurs")
    ):
        raise AssertionError(
            "the GPU client drill-down overlay never rendered its engine or "
            "memory-region sections"
        )
    # A list only exists when there is something to choose, so its presence is
    # host-dependent -- but if the host offered one, the drill-down has to be
    # able to leave it again, which is what the two Escs above assert by
    # reaching a clean quit rather than timing out.
    if "选择".encode() in out or b"selects" in out:
        assert b"ID " in out, "a client list named no client id"


def run_layout_drop_target() -> None:
    """Edit mode's drop-target list: open it, switch sides, name the panel.

    `m` is the key that turns a one-place nudge into a drop, so the sequence
    that matters is open -> the panel being moved is named -> the side is
    shown.  Left is pressed because the side keys *set* rather than flip, and
    the default is "after".  `Enter` is deliberately not sent: committing a
    drop rewrites the persisted layout, and this scenario must not touch the
    developer's file.
    """
    script: list[tuple[object, object]] = [
        (b"e", None),                      # layout edit mode
        (("sleep", 0.8), None),
        (b"m", None),                      # drop-target list
        (("sleep", 0.8), None),
        (b"\x1b[D", None),                 # left: the side keys set, not flip
        (("sleep", 0.5), None),
        # The renderer repaints only the cells that changed, and "after" and
        # "before" differ in one character, so the whole line never appears in
        # the byte stream.  A resize forces a complete repaint.
        (("resize", 46, 160), None),
        (("resize", 45, 160), None),
        (("sleep", 0.8), None),
    ]
    # `q` closes an open overlay before it quits, so the session needs two.
    out = run_session(160, 45, exercise=False,
                      script=script + [(b"q", None), (("sleep", 0.5), None), (b"q", None)])
    assert any(
        marker.encode() in out
        for marker in ("移动", "Move ", "Verschieben", "Mover ", "Déplacer ",
                       "移動", "이동", "Mover ", "Переместить ")
    ), "the drop-target list never named the panel being moved"
    assert any(
        marker.encode() in out
        for marker in ("之前", "before", "davor", "avant", "앞", "перед")
    ), "the drop-target list never showed the chosen side"
    assert b"Enter" in out or "Enter".encode() in out, (
        "the drop-target list never showed how to commit"
    )


def run_workspace_unicode_name() -> None:
    """A workspace name typed in the user's own script, and kept across a restart.

    The name rule admits a well-formed UTF-8 sequence rather than a C-locale
    character class, so a zh-CN user can name a workspace the way they talk about
    it. What has to hold is the part that is easy to get wrong: the session
    accepts the name, the layout file is written with it quoted as a key, and a
    *fresh process* reads that file back and shows the name. A rule the writer
    and the reader do not share would accept the name on the way out and reject
    the whole file on the way back in, which costs the user every workspace
    rather than one.

    The name is prefixed with `w1` for a reason that is about this file rather
    than about the feature: `工作区` is also the zh-CN word for "Workspaces", so
    it is already on the wire as a heading and a hint, and asserting on it would
    pass whether or not the feature works. `w1工作区` is a name no translation
    contains, so its presence in the stream means the name survived.

    The second session shares a temporary config home with the first, so the file
    is written and read for real without touching the developer's layout.
    """
    name = "w1工作区"
    with tempfile.TemporaryDirectory() as directory:
        home = pathlib.Path(directory)
        first = run_session(160, 45, exercise=False, config_home=home, script=[
            (b"e", None),                              # layout edit mode
            (("sleep", 0.9), None),
            (b"w", None),                              # workspace list
            (("sleep", 0.9), None),
            (b"\x1b[B", None),                         # down onto the new row
            (("sleep", 0.5), None),
            (name.encode(), None),                     # type it
            (("sleep", 0.9), None),
            (b"\r", None),                             # commit
            (("sleep", 0.9), None),
            (b"\x1b", None), (("sleep", 0.4), None),    # leave edit mode
            (b"q", None),                              # quit, writing the layout
        ])
        assert name.encode() in first, (
            "the typed name never reached the screen, so the input path or the "
            "draft is not accepting it"
        )
        # The name is a key in the file, so it has to be written quoted; a bare
        # CJK key would not survive the reader.
        layout = home / "wtop" / "layout.yml"
        assert layout.is_file(), f"the session did not write {layout}"
        contents = layout.read_text(encoding="utf-8")
        assert f'"{name}"' in contents, (
            "the name was not written as a quoted key:\n" + contents
        )
        assert f'active: "{name}"' in contents, (
            "the workspace the session ended on is not the one it wrote:\n" + contents
        )

        # The restart is the half that matters. If the reader disagreed with the
        # writer, this process would come up without the workspace, and the name
        # could not be on the wire at all.
        second = run_session(160, 45, exercise=False, config_home=home, script=[
            (("sleep", 1.5), None),
            (b"e", None),                              # edit mode
            (("sleep", 1.0), None),
            (b"w", None),                              # workspace list
            (("sleep", 1.0), None),
            (("resize", 46, 160), None),               # complete repaint
            (("resize", 45, 160), None),
            (("sleep", 0.8), None),
            (b"\x1b", None), (("sleep", 0.4), None),    # close the list
            (b"\x1b", None), (("sleep", 0.4), None),    # leave edit mode
            (b"q", None),
        ])
        assert name.encode() in second, (
            "the workspace did not survive the restart, so the reader and the "
            "writer disagree about which names exist; the layout was rejected "
            "and every workspace with it"
        )


def run_workspace_manager() -> None:
    """Edit mode's workspace list: open it, type a name, confirm it appears.

    The overlay is a live list rather than a prompt, so the sequence that
    matters is open -> move to the new row -> type -> the typed name is on
    screen.  `Enter` is deliberately not sent: committing a workspace writes
    the persisted layout, and this scenario must not touch the developer's
    layout file.
    """
    script: list[tuple[object, object]] = [
        (b"e", None),                      # layout edit mode
        (("sleep", 0.8), None),
        (b"w", None),                      # workspace list
        (("sleep", 0.8), None),
        (b"\x1b[B", None),                 # down onto the new-workspace row
        (("sleep", 0.5), None),
        (b"ptycheck", WORKSPACE_MANAGER_MARKERS),  # type, once painted
        (("sleep", 0.8), None),
    ]
    # Esc is two-level here, and `q` is not the way out any more: on the
    # new-workspace row every printable key is text, so `q` would be typed into
    # the name rather than closing anything.  One Esc clears the typed name, the
    # next closes the list, and only then does `q` reach the main view.
    out = run_session(160, 45, exercise=False, script=script + [
        (b"\x1b", None), (("sleep", 0.5), None),   # clear the typed name
        (b"\x1b", None), (("sleep", 0.5), None),   # close the list
        (b"q", None),                               # quit
    ])
    assert any(
        marker.encode() in out
        for marker in ("工作区", "Workspaces", "Arbeitsbereiche", "Espacios de trabajo",
                       "Espaces de travail", "ワークスペース", "워크스페이스",
                       "Espaços de trabalho", "Рабочие пространства")
    ), "the workspace list never rendered its title"
    assert b"ptycheck" in out, "the typed workspace name never reached the screen"


def run_cgroup_cross_link() -> None:
    """Reaching from a workload into its processes and back out again.

    The Workloads page already lists cgroup.procs for every node, so `Enter`
    must turn that member set into a process-table filter, announce which
    cgroup is narrowing the rows, and let one Escape put the table back.  A
    filter that silently hid rows would pass the same frame check, so both
    the presence and the absence are asserted.
    """
    script: list[tuple[object, object]] = [
        (PAGE_KEYS[8].encode("ascii"), None),
        (("sleep", 1.0), None),
        (b"\r", None),
        (("sleep", 1.5), None),
    ]
    filtered = VirtualScreen(160, 45)
    filtered.feed(run_session(160, 45, exercise=False, script=script + [(b"q", None)]))
    filtered_text = filtered.text()
    assert "cgroup：" in filtered_text, (
        "Enter on a workload did not announce the cgroup filter on the process table"
    )
    assert "个进程" in filtered_text, (
        "Enter on a workload did not report how many processes it found"
    )
    assert "Esc 清除" in filtered_text, (
        "the cgroup filter does not say how to clear it"
    )

    script.append((b"\x1b", None))
    script.append((("sleep", 1.5), None))
    script.append((b"q", None))
    cleared = VirtualScreen(160, 45)
    cleared.feed(run_session(160, 45, exercise=False, script=script))
    assert "cgroup：" not in cleared.text(), (
        "Escape did not clear the cgroup filter"
    )


def run_cgroup_health() -> None:
    """The Workloads page must not report a healthy cgroup tree as partial.

    A controller that was never delegated to a subtree has no control files in
    it, and that is the kernel's decision rather than a read that failed.  The
    page used to open a "Why partial" section blaming undelegated controllers
    and a denied read alike, so on an ordinary systemd host most cgroups were
    flagged.  When the collector can enumerate the tree it can read, the count
    is zero and no explanation is offered.  The stale wording is asserted absent
    as well, because it is no longer true at any partial count.
    """
    script: list[tuple[object, object]] = [
        (PAGE_KEYS[8].encode("ascii"), None),
        (("sleep", 2.0), None),
        (b"q", None),
    ]
    screen = VirtualScreen(160, 45)
    screen.feed(run_session(160, 45, exercise=False, script=script))
    text = screen.text()
    for marker in PAGE_MARKERS[8]:
        assert marker in text, f"the Workloads page did not render: {marker!r}"
    assert "可见 cgroup" in text, "the cgroup detail panel did not render"
    assert "委派" not in text, (
        "the Workloads page still blames undelegated controllers for being partial"
    )
    assert "为何是部分数据" not in text, (
        "a cgroup tree with nothing unreadable still opens a partial explanation"
    )


def run_gpu_device_clocks() -> None:
    """`k` on the GPU page opens the device's own clock domains, side by side.

    The device table promotes one clock into a single Frequency cell and, when a
    card publishes several, says how many it is not showing.  That stops the
    cell implying it is the only clock the device has, and it still leaves every
    other clock unreadable anywhere on screen.  A client has had that view one
    level down since the DRM drill-down; this is the level above it, and the
    one that exists when no client is running at all.

    The interesting part of the sequence is the single Escape.  A host with one
    GPU never had a picker, so an Escape that "stepped back a level" would
    re-render the same detail and change nothing on screen, leaving the overlay
    reachable only by a second Escape.  Reaching a clean exit after one Escape
    and one `q` is what pins that.

    The invariant that no clock here may read 0 Hz is asserted in
    `test_gpu_device_clocks`, against rendered screens, with the number parsed
    rather than the text matched -- "300 MHz" contains "0 MHz", so a substring
    assertion over a page of correct clocks fails on the correct answer.  This
    case asserts the wiring instead, and a host with no GPU at all legitimately
    has no device to open, which must not fail the matrix.
    """
    out = run_session(160, 45, exercise=False, script=[
        (PAGE_KEYS[7].encode("ascii"), None),   # GPU page
        (("sleep", 1.2), None),
        (b"k", None),
        (("sleep", 1.5), None),
        (b"\x1b", None),                        # close the overlay in one press
        (("sleep", 0.6), None),
        (b"q", None),                           # quit
    ])
    if not any(
        marker.encode() in out
        for marker in ("设备频率域", "Device clocks", "Geräte-Takt", "Horloges de l'appareil")
    ):
        return                                  # no GPU on this host: nothing to open
    # The close hint is asserted on its ASCII half only.  The renderer is a
    # cell-grid diff, so a localized phrase is not contiguous on the wire: the
    # "Esc/Enter" run is followed straight by a cursor move and the translated
    # "关闭" arrives in a later cell batch, and matching the whole phrase fails
    # against a screen that is perfectly correct.
    assert b"Esc/Enter" in out, (
        "the device clock overlay did not say how to close itself"
    )
    # The clock the table is currently showing is named as such, which is the
    # fact the table cell cannot carry and the reason this screen exists.
    if any(marker.encode() in out for marker in ("表格中显示", "shown in the table")):
        assert any(
            marker.encode() in out
            for marker in ("i915_gt", "xe_gt", "amdgpu_dpm", "i915_legacy", "Source", "来源")
        ), "a named clock did not say which source it was read from"


def run_signal_shutdown() -> None:
    """SIGTERM, SIGHUP, and SIGINT must exit like `q`: status 0, alternate
    screen restored, never killed by the signal itself."""
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        script: list[tuple[object, object]] = [
            (("sleep", 1.2), None),
            (("signal", number), None),
        ]
        run_session(100, 30, exercise=False, script=script)


def run_tmux_scenario() -> None:
    """The PTY harness drives a bare pseudo-terminal; tmux sits between the
    application and the outer terminal and rewrites what it emits. One real
    tmux pane per run proves startup, rendering, input, and clean exit all
    survive a multiplexer."""
    if shutil.which("tmux") is None:
        print("PTY tmux scenario: skipped (tmux not installed)")
        return
    session = "wtop-pty-tmux-%d" % os.getpid()
    environment = os.environ.copy()
    if EXECUTABLE:
        command = EXECUTABLE
        environment["LUA_PATH"] = ""
        environment["LUA_CPATH"] = ""
    else:
        command = "%s %s" % (LUA, shlex.quote(str(ROOT / "src/wtop.lua")))
        environment["LUA_PATH"] = f"{ROOT}/src/?.lua;{ROOT}/src/?/init.lua;;"
        environment["LUA_CPATH"] = f"{ROOT}/build/native/?.so;;"
    environment["TERM"] = "screen-256color"
    environment.pop("COLORTERM", None)
    arguments = ["--interval", "300", "--lang", "en-US"]
    if EXECUTABLE:
        command_line = "%s %s" % (command, " ".join(shlex.quote(a) for a in arguments))
    else:
        command_line = "%s %s" % (command, " ".join(shlex.quote(a) for a in arguments))
    try:
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", session, "-x", "120", "-y", "34",
             command_line],
            check=True, env=environment, timeout=10,
        )
        deadline = time.monotonic() + 12.0
        pane_text = ""
        while time.monotonic() < deadline:
            capture = subprocess.run(
                ["tmux", "capture-pane", "-p", "-t", session],
                capture_output=True, text=True, timeout=5,
            )
            pane_text = capture.stdout
            if "wtop" in pane_text:
                break
            time.sleep(0.2)
        assert "wtop" in pane_text, "wtop did not render inside the tmux pane"
        subprocess.run(["tmux", "send-keys", "-t", session, "2"],
            check=True, timeout=5)
        time.sleep(1.0)
        capture = subprocess.run(
            ["tmux", "capture-pane", "-p", "-t", session],
            capture_output=True, text=True, timeout=5,
        )
        assert "PID" in capture.stdout or "进程" in capture.stdout, (
            "page switch inside tmux did not reach the process table"
        )
        subprocess.run(["tmux", "send-keys", "-t", session, "q"],
            check=True, timeout=5)
        exited = time.monotonic() + 8.0
        while time.monotonic() < exited:
            probe = subprocess.run(["tmux", "has-session", "-t", session],
                capture_output=True, timeout=5)
            if probe.returncode != 0:
                print("PTY tmux pane render/input/exit: ok")
                return
            time.sleep(0.2)
        raise AssertionError("wtop did not exit from q inside tmux")
    finally:
        subprocess.run(["tmux", "kill-session", "-t", session],
            capture_output=True, timeout=5)


def run_thread_drilldown() -> None:
    """Processes -> a process -> one of its threads -> that thread's detail.

    The thread table in the process overlay only shows a slice of the busiest
    threads, so `i` is the key that has to reach the rest, and Enter after it
    has to open a view built from the thread's *own* procfs files.  The thread
    group is the assertion that matters most: it is the number that says which
    process the thread belongs to, and it is read rather than assumed.

    The assertions are on the raw stream rather than a reconstructed screen
    because the session has to be closed with two `q` presses -- the first
    closes the open overlay -- and by then the final frame is the bare table.
    """
    script: list[tuple[object, object]] = [
        (PAGE_KEYS[2].encode("ascii"), None),   # processes page
        (("sleep", 1.0), None),
        (b"\r", None),                           # process detail
        (("sleep", 1.5), None),
        (b"i", None),                            # thread picker
        (("sleep", 1.2), None),
    ]
    # `End` before the capture, for the same reason as the thread detail below:
    # an overlay taller than its body window puts its action line below the fold,
    # and the picker grows with the thread count.  When the picker does fit, the
    # maximum offset is zero and the key changes nothing, so this costs the
    # scenario nothing on a quiet host and saves it on a busy one.
    picker = run_session(160, 45, exercise=False,
                         script=script + [(b"\x1b[F", None), (b"q", None),
                                          (("sleep", 0.4), None), (b"q", None)])
    picker_text = picker.decode("utf-8", "replace")
    assert "进程详情" in picker_text, "Enter did not open the process overlay"
    assert "选择线程" in picker_text, (
        "`i` in the process overlay did not open the thread picker"
    )
    assert "上下选择" in picker_text, (
        "the thread picker does not say how to move the cursor"
    )

    script.append((b"\r", None))                # inspect the highlighted thread
    # Two refreshes: the first lands the per-thread read, the second has an
    # interval to difference, and the run-queue rate only exists once it does.
    script.append((("sleep", 1.8), None))
    script.append((("sleep", 1.8), None))
    # The renderer repaints only the cells that changed, and a resize forces a
    # complete repaint, so the values that arrived after the overlay opened are
    # on the wire as whole lines rather than as scattered single cells.
    #
    # `End` first, and that key is the whole difference between this scenario
    # working and not.  The thread detail is taller than the overlay's body
    # window -- it carries the thread's own run queue, context switches, I/O,
    # cgroup and source lines -- and its action hint is the *last* of them, so
    # it sits below the fold.  Nothing is wrong with the product here: a
    # scrollable overlay is allowed to hide its tail, and the key that reveals
    # it is one a user presses.  The assertion was checking a line neither the
    # user nor the harness could see, which is why it read as a flake and then
    # as a 0-in-8 failure when the scenario ran on its own.  Viewport height is
    # not the lever: measured at 45, 60 and 75 rows it failed identically every
    # time, because the content grows with the thread's data rather than with
    # the terminal.
    script.append((b"\x1b[F", None))             # scroll the overlay to its end
    script.append((("resize", 46, 160), None))
    script.append((("resize", 45, 160), None))
    script.append((("sleep", 0.8), None))
    detail = run_session(160, 45, exercise=False,
                         script=script + [(b"q", None), (("sleep", 0.4), None), (b"q", None)])
    detail_text = detail.decode("utf-8", "replace")
    assert "线程详情" in detail_text, (
        "Enter on a thread row did not open the thread detail"
    )
    assert "TID" in detail_text, "the thread detail does not name the TID"
    assert "线程组" in detail_text, (
        "the thread detail does not report the thread group, which is the only "
        "place the owning process is confirmed from the thread's own data"
    )
    assert "Esc 返回线程列表" in detail_text, (
        "the thread detail does not say how to go back"
    )
    assert "控制组" in detail_text, (
        "the thread detail states no verdict about the thread's control group"
    )
    # schedstat and sched are read for the selected thread only, so a host that
    # publishes them must reach the overlay.  The policy is the part that
    # arrives on the very first read; the rates need a second sample to have an
    # interval to divide by, which is why the script waits twice.
    assert "SCHED_" in detail_text, (
        "the thread detail did not report the scheduling policy from the "
        "thread's own sched file"
    )
    assert "队列等待" in detail_text and "/s" in detail_text, (
        "the thread detail did not report the run-queue wait rate, which is the "
        "only figure that separates a starved thread from a busy one"
    )

    # The two new rows are asserted on the reconstructed screen, row by row.
    # "切换" cannot be matched in the raw stream: the cumulative counters above
    # it are already labelled 自愿切换 and 非自愿切换, so the word is on the wire
    # whether or not the rate exists.  What distinguishes the rate is that its
    # label occupies a cell of its own -- the overlay is drawn inside the main
    # frame, so every row starts with the table's border and no row starts with
    # a label, and the cells are what carry the distinction.
    #
    # Cells are compared as whole whitespace-separated tokens rather than as
    # substrings, which is what makes 切换 and 自愿切换 different cells rather
    # than one being a prefix of the other.
    # The cut is the memory section's own last row, which is the end of the
    # overlay's final frame: everything this case reads sits above it.
    rows = _screen_at_last_paint(
        detail, ("USS".encode(), "PSS".encode(), "属于进程".encode()), 160, 45
    )
    cells = [set(row.split()) for row in rows]
    assert any("切换" in row for row in cells), (
        "the thread detail has no switch-rate row:\n" + "\n".join(rows)
    )
    assert any(
        "切换" in row and any(cell.endswith("/s") for cell in row) for row in cells
    ), (
        "the switch figure is a cumulative total, not a rate over an interval:\n"
        + "\n".join(rows)
    )
    # The preempted share is not asserted as present: a thread that switched not
    # at all in the interval has no share to report, and whether the picker
    # lands on such a thread is up to the host.  What *is* asserted is the
    # relationship, which holds either way -- a zero switch rate is a real
    # measurement and carries no share, because a fraction of nothing would
    # claim nothing was preempted, which is not what was measured.
    switch_total = next(
        (cell for row in cells if "切换" in row for cell in row if cell.endswith("/s")),
        None,
    )
    assert switch_total is not None
    preempted = [row for row in cells if "被抢占占比" in row]
    if switch_total == "0.0/s":
        assert not preempted, (
            "a thread that switched not at all drew a preempted share:\n"
            + "\n".join(rows)
        )
    else:
        assert preempted, (
            "a thread that did switch drew no preempted share, so the only "
            "per-thread signal that separates a starved thread from a blocked "
            "one is missing:\n" + "\n".join(rows)
        )
    # The memory section must say whose memory it is, and it says so in the
    # heading rather than in a footnote: a byte count under a thread's name is
    # otherwise read as the thread's.  The whole label is matched, because the
    # negative cannot be: "属于线程" is a substring of the correct heading
    # ("内存（属于进程，不属于线程）"), so testing for it would fail on the very
    # text that gets the attribution right.
    assert any("内存（属于进程，不属于线程）" in row for row in rows), (
        "the thread detail shows no memory section saying the memory is the "
        "process's, or the section is labelled ambiguously:\n" + "\n".join(rows)
    )
    assert any("PSS" in row for row in cells) and any("USS" in row for row in cells), (
        "the memory section states whose memory it is but names no figure:\n"
        + "\n".join(rows)
    )


def run_process_columns() -> None:
    """`C` on the processes page must open the column editor and act on it.

    The editor is the only way to change what the table shows, so the sequence
    that matters is open -> the editor names itself -> a column is hidden -> the
    table's header loses that column.  Both halves are asserted: an editor that
    lists columns but does not change the table would pass the first check
    alone.

    Hiding a *required* column is the interesting refusal, and it is asserted
    too: PID and Command identify a row, so Space on them must say so rather than
    silently doing nothing.
    """
    script: list[tuple[object, object]] = [
        (PAGE_KEYS[2].encode("ascii"), None),   # processes page
        (("sleep", 1.0), None),
        (b"C", None),
        (("sleep", 1.0), None),
    ]
    editor = run_session(160, 45, exercise=False,
                         script=script + [(b"q", None), (("sleep", 0.4), None), (b"q", None)])
    editor_text = editor.decode("utf-8", "replace")
    assert "进程列" in editor_text, (
        "`C` on the processes page did not open the column editor"
    )
    assert "空格" in editor_text, (
        "the column editor does not say how to show and hide a column"
    )
    assert "←/→" in editor_text, (
        "the column editor does not say how to reorder a column"
    )
    assert "随布局保存" in editor_text, (
        "the column editor does not say that the choice is saved with the "
        "layout, which is what it is: the next session opens with the same "
        "table"
    )
    for column in ("PID", "TIME+", "命令"):
        assert column in editor_text, (
            f"the column editor does not list {column}"
        )
    assert "始终显示" in editor_text, (
        "the editor does not say which columns it will refuse to hide"
    )

    # Hide TIME+ and confirm the table's header loses it.  The cursor starts on
    # PID, so it is walked down to TIME+ first (pid, user, PRI, NI, Virt, Res,
    # S, CPU, TIME+).
    for _ in range(8):
        script.append((b"\x1b[B", None))
    script.append((("sleep", 0.6), None))
    script.append((b" ", None))                 # space toggles the column
    script.append((("sleep", 0.8), None))
    script.append((("resize", 46, 160), None))  # force a complete repaint
    script.append((("resize", 45, 160), None))
    script.append((("sleep", 0.8), None))
    # The raw stream cannot answer this one: the editor itself listed TIME+ a
    # moment earlier, so the word is on the wire no matter what the table did.
    # Only the reconstructed final screen shows what the table is now drawing.
    final = VirtualScreen(160, 45)
    final.feed(run_session(160, 45, exercise=False,
                           script=script + [(b"q", None), (("sleep", 0.4), None), (b"q", None)]))
    table_text = final.text()
    assert "进程列" not in table_text, "the editor did not close"
    assert "TIME+" not in table_text, (
        "hiding a column in the editor did not remove it from the table header"
    )
    assert "PID" in table_text and "CPU" in table_text, (
        "hiding one column emptied the header; the others must survive"
    )


def run_workspace_rename() -> None:
    """`r` renames a saved workspace, and the new name reaches the file.

    The name chosen here is `my qx` on purpose.  It carries the two things that
    used to be impossible, so one session covers both bugs: `q` and `x` were
    matched as commands before the printable-key branch, which meant a
    workspace could not be *named* with either letter in it; and a name with a
    space was written out as a bare YAML key that this same reader then refused,
    so the exit save replaced a good layout.yml with a file the next start could
    not read.  A rename feature that could not produce such a name would not
    have found either of them.

    The file is read after the quit, so the assertion is on what was persisted
    rather than on what the status line claimed.
    """
    with tempfile.TemporaryDirectory(prefix="wtop-pty-wsrename-") as temporary:
        home = pathlib.Path(temporary)
        # One session to create a workspace to rename, so that the rename in the
        # second session starts from a name that came back off the file rather
        # than from this session's memory.
        out = run_session(160, 45, exercise=False, script=[
            (b"e", None),                      # layout edit mode
            (("sleep", 0.8), None),
            (b"w", None),                      # no workspaces yet: the New row
            (("sleep", 0.8), None),
            # Gated on the manager actually being painted: this scenario's
            # assertion reads the manager hint out of the transcript, and under
            # load the sleeps above do not bound when (or whether) that frame
            # reached the wire before the keys that follow close the overlay.
            # The gate is what the marker column exists for -- the CI failure
            # this fixes was exactly a hint that had never been painted.
            (b"alpha", WORKSPACE_MANAGER_MARKERS),   # a name to rename later
            (("sleep", 0.6), None),
            (b"\r", None),                     # save it; the overlay closes
            (("sleep", 0.8), None),
            (b"q", None),                      # quit, which writes the file
        ], config_home=home)
        # The hint is how the user learns `r` exists, so it is asserted rather
        # than assumed; the zh-CN catalog is what this profile loads.
        assert "r 重命名".encode() in out, (
            "the workspace manager hint does not mention r"
        )

        out = run_session(160, 45, exercise=False, script=[
            (b"e", None),
            (("sleep", 0.8), None),
            (b"w", None),                      # cursor on the workspace from the file
            (("sleep", 0.8), None),
            (b"r", WORKSPACE_MANAGER_MARKERS),  # rename, once the list is painted
            (("sleep", 0.8), None),
            (b"\x7f" * 5, None),               # clear it
            (("sleep", 0.6), None),
            (b"my qx", WORKSPACE_RENAME_MARKERS),
            (("sleep", 0.8), None),
            (b"\r", None),                     # commit
            (("sleep", 0.9), None),
            # Gated on the confirmation having been painted: the status line
            # below asserts on it, and a quit that fires before the repaint
            # reaches the wire erases the very frame the assertion reads.
            (b"q", WORKSPACE_RENAMED_MARKERS),  # quit, which saves
        ], config_home=home)
        # Short fragments, not whole sentences: the renderer emits a diff and
        # positions the cursor between styled segments, so a long translated
        # string is on the wire in pieces.  Each of these appears in exactly one
        # place -- the manager hint, the rename hint, or the status line -- so a
        # hit means that state was really on screen.
        for probe, what in (
            ("重命名", "the manager hint does not offer r"),
            ("取消", "the rename hint does not say that Esc cancels"),
            ("已重命名为", "the rename was never confirmed in the status line"),
            ("my qx", "the status line does not name the workspace it renamed to"),
        ):
            assert probe.encode() in out, what + f" (looked for {probe!r})"

        layout = home / "wtop" / "layout.yml"
        assert layout.is_file(), f"the rename was not written to {layout}"
        contents = layout.read_text(encoding="utf-8")
        assert '"my qx"' in contents, (
            "the renamed workspace did not reach layout.yml, or was written as "
            "a key this reader cannot parse:\n" + contents
        )
        assert '"alpha"' not in contents, (
            "the old name is still in the file:\n" + contents
        )
        # The file the save produced has to be one a fresh start can read, and
        # that is the half the string checks above cannot see: a name written as
        # a bare key is present in the text and still unreadable.  The same
        # reader the TUI uses, asked the same question.
        probe = subprocess.run(
            [LUA, "-e", """
                package.path = %r .. "/src/?.lua;" .. %r .. "/src/?/init.lua;" .. package.path
                local store = require("wtop.layout_store")
                local handle = assert(io.open(%r, "rb"))
                local text = handle:read("*a")
                handle:close()
                local orders, err = store.parse(text, require("wtop.workspace").default_orders(), %r)
                if not orders then print("REFUSED: " .. tostring(err)) os.exit(1) end
                local _, _, workspaces, active = store.parse(text,
                    require("wtop.workspace").default_orders(), %r)
                if type(workspaces) ~= "table" or workspaces[%r] == nil then
                    print("NO SUCH WORKSPACE") os.exit(1)
                end
                print("ok:" .. tostring(active))
            """ % (str(ROOT), str(ROOT), str(layout), str(layout), str(layout), "my qx")],
            capture_output=True, text=True, cwd=str(ROOT),
        )
        assert probe.returncode == 0, (
            "the layout the rename produced cannot be read back by the loader: "
            + probe.stdout.strip() + probe.stderr.strip() + "\n" + contents
        )
        assert probe.stdout.strip() == "ok:my qx", (
            "the loader read the file but not the renamed workspace: " + probe.stdout.strip()
        )


def run_process_columns_persistence() -> None:
    """A column the user hid must still be hidden in the next session.

    The choice is written to layout.yml, so this is two separate facts and the
    case asserts both.  The file has to carry the column set, and a process
    started against that file has to draw the table without the column.  The
    first assertion alone would pass with a store that saves a list nothing
    reads -- which is exactly the half of this that unit tests cannot see.
    """
    with tempfile.TemporaryDirectory(prefix="wtop-pty-cols-") as temporary:
        home = pathlib.Path(temporary)
        script: list[tuple[object, object]] = [
            (PAGE_KEYS[2].encode("ascii"), None),   # processes page
            (("sleep", 1.0), None),
            (b"C", None),
            (("sleep", 1.0), None),
        ]
        # The cursor starts on PID; walk down to TIME+ (pid, user, PRI, NI,
        # Virt, Res, S, CPU, TIME+), hide it, then leave: the first `q` closes
        # the editor and the second one quits, which is what runs the save.
        for _ in range(8):
            script.append((b"\x1b[B", None))
        script.extend([
            (("sleep", 0.6), None),
            (b" ", None),
            (("sleep", 0.8), None),
            (b"q", None),
            (("sleep", 0.5), None),
            (b"q", None),
        ])
        first = run_session(160, 45, exercise=False, script=script, config_home=home)
        assert "进程列" in first.decode("utf-8", "replace"), (
            "the column editor never opened, so nothing was saved"
        )

        layout = home / "wtop" / "layout.yml"
        assert layout.is_file(), f"the column choice was not written to {layout}"
        contents = layout.read_text(encoding="utf-8")
        assert "schema_version: 4\n" in contents, (
            "a session that changed the columns did not write a v4 layout:\n" + contents
        )
        assert "process_columns:\n" in contents, (
            "the saved layout carries no column set:\n" + contents
        )
        # The keys are quoted, the way every other identifier in the file is.
        assert '\n  - "time"\n' not in contents, (
            "a column hidden in the editor was written to the file anyway:\n" + contents
        )
        assert '\n  - "pid"\n' in contents and '\n  - "name"\n' in contents, (
            "the identifying columns are missing from the saved set:\n" + contents
        )

        # The second session runs against that file and must open with the
        # table the first one left.  The editor is never opened, so TIME+ on
        # the wire can only have come from the table's own header.
        second = run_session(160, 45, exercise=False, script=[
            (PAGE_KEYS[2].encode("ascii"), None),
            (("sleep", 1.4), None),
            (("resize", 46, 160), None),
            (("resize", 45, 160), None),
            (("sleep", 0.8), None),
            (b"q", None),
        ], config_home=home)
        screen = VirtualScreen(160, 45)
        screen.feed(second)
        text = screen.text()
        assert "TIME+" not in text, (
            "the next session drew a column the previous session hid:\n" + text
        )
        assert "PID" in text and "CPU" in text, (
            "the restored table is missing the columns that were left on:\n" + text
        )


def run_process_queued_column() -> None:
    """The run-queue column is measured for the viewport, so switching it on has
    to make numbers appear in the table -- and only after a second sample.

    The column is hidden by default, so the test has to switch it on first; and
    the figure is a rate, so the header can legitimately be blank for one tick
    after it appears.  Both halves are asserted: a column that renders but stays
    empty, and a column that appears with a stale total instead of a rate, are
    the two ways this could look finished and be lying.
    """
    script: list[tuple[object, object]] = [
        (PAGE_KEYS[2].encode("ascii"), None),   # processes page
        (("sleep", 1.0), None),
        (b"C", None),                           # column editor
        (("sleep", 1.0), None),
    ]
    # Walk the cursor to the run-queue column.  It is the last entry, so End
    # reaches it directly rather than counting arrow presses.
    script.append((b"\x1b[F", None))            # End
    script.append((("sleep", 0.6), None))
    script.append((b" ", None))                 # show it
    script.append((("sleep", 0.6), None))
    editor = run_session(160, 45, exercise=False,
                         script=script + [(b"q", None), (("sleep", 0.4), None), (b"q", None)])
    editor_text = editor.decode("utf-8", "replace")
    assert "队列等待" in editor_text, (
        "the column editor does not offer the run-queue column"
    )

    # Two refreshes so the rate has an interval to divide by, then a resize to
    # force a complete repaint of the header.
    script.append((("sleep", 1.6), None))
    script.append((("sleep", 1.6), None))
    script.append((("resize", 46, 160), None))
    script.append((("resize", 45, 160), None))
    script.append((("sleep", 1.0), None))
    final = VirtualScreen(160, 45)
    final.feed(run_session(160, 45, exercise=False,
                           script=script + [(b"q", None), (("sleep", 0.4), None), (b"q", None)]))
    # VirtualScreen.text() already reconstructs clean cells, so the header can be
    # matched directly.
    text = final.text()
    assert "进程列" not in text, "the column editor did not close"
    header = next((line for line in text.splitlines()
                   if "PID" in line and "CPU" in line), "")
    assert "队列等待" in header, (
        "the run-queue column was switched on but is not in the table header: "
        + header
    )
    # At least one row must carry a figure with a per-second suffix; a header
    # with a column of nothing is the failure this guards against.
    assert "/s" in text, (
        "the run-queue column is in the header but no row carries a rate, so "
        "the viewport is either not being measured or the rate never appeared"
    )


# The scenarios this file runs, named.  The isolation mode below needs the list
# to be *data* rather than the order `main` happens to call them in: a scenario
# that only passes because something before it warmed the host is not a scenario
# that passes, and the only way to see that is to run it first.
SCENARIOS = (
    "run_ascii_profile",
    "run_cgroup_cross_link",
    "run_cgroup_health",
    "run_gpu_client_drilldown",
    "run_gpu_device_clocks",
    "run_gpu_device_frequency",
    "run_layout_drop_target",
    "run_process_columns",
    "run_process_columns_persistence",
    "run_process_queued_column",
    # `run_responsive` is here because the step that failed intermittently was
    # the 200x45 page-switch check *inside* it, and the isolation mode could not
    # reach it: a scenario list has to be checked against the code that runs the
    # scenarios, and reporting 17/17 while one of the matrix's steps sat outside
    # what the sweep covers is the same accounting error the sweep exists to
    # remove.  The sweep reported green on the very runs the matrix was failing.
    "run_responsive",
    "run_resize_storm",
    "run_signal_shutdown",
    "run_thread_drilldown",
    "run_tmux_scenario",
    "run_workspace_manager",
    "run_workspace_rename",
    "run_workspace_unicode_name",
)


def run_isolation(scenario: str | None = None) -> None:
    """Each scenario alone, in its own process.

    Two failures in this file's history came from a scenario depending on what
    ran before it.  The thread-drilldown one is the sharp example: it passed
    inside the full matrix and failed **0 times out of 8** when run on its own,
    and the reason -- an assertion reading the last line of an overlay that has
    to be scrolled to see -- is invisible from inside a passing suite.  A fresh
    process per scenario is the only arrangement in which "does this pass?" means
    the question people think it means; sharing a process lets module state, the
    config home and the host's own load profile carry over from the previous
    scenario, and a scenario that inherits a warm host is not being tested.

    A scenario that cannot run here -- tmux absent, say -- is reported as such
    rather than skipped, because a skip and a pass look identical in a summary
    and only one of them is evidence.
    """
    if scenario is not None:
        getattr(pty_smoke_module, scenario)()
        print(f"PTY isolated {scenario}: ok")
        return
    failures: list[tuple[str, str]] = []
    absent: list[tuple[str, str]] = []
    for name in SCENARIOS:
        if not hasattr(pty_smoke_module, name):
            raise SystemExit(f"no such scenario: {name}")
        result = subprocess.run(
            [sys.executable, str(pathlib.Path(__file__).resolve()),
             "--scenario", name],
            capture_output=True, text=True, timeout=300,
        )
        if result.returncode == 0:
            print(f"PTY isolated {name}: ok", flush=True)
            continue
        message = (result.stderr or result.stdout or "").strip().splitlines()
        detail = message[-1][:100] if message else f"exit {result.returncode}"
        if "skipped" in detail.lower() or "not installed" in detail.lower():
            absent.append((name, detail))
            print(f"PTY isolated {name}: SKIPPED ({detail})", flush=True)
        else:
            failures.append((name, detail))
            print(f"PTY isolated {name}: FAILED ({detail})", flush=True)
    print("")
    print(f"{len(SCENARIOS) - len(failures) - len(absent)}/{len(SCENARIOS)} "
          "scenarios pass on their own")
    for name, detail in absent:
        print(f"  skipped: {name}: {detail}")
    for name, detail in failures:
        print(f"  FAILED:  {name}: {detail}")
    if failures:
        raise SystemExit(1)


def run_responsive() -> None:
    """The eight-size matrix, then the page-switch check that closes it.

    This was a block inside `main` with no name of its own, which is why the
    isolation mode could not reach it: the 200x45 page-switch step inside is the
    one that failed intermittently, and `--scenario` had nothing to name.  A tool
    built to answer "does this pass on its own" is only as good as the names it
    can be given, so the block became a scenario like every other.
    """
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
    run_resize_storm()
    print("PTY 80x24 after 49-step resize storm: ok")
    run_tmux_scenario()
    run_signal_shutdown()
    print("PTY SIGTERM/SIGHUP/SIGINT shutdown: ok")
    return captures


def main() -> None:
    global pty_smoke_module
    if "--scenario" in sys.argv:
        name = sys.argv[sys.argv.index("--scenario") + 1]
        if name not in SCENARIOS:
            raise SystemExit(f"--scenario must name one of {len(SCENARIOS)} scenarios")
        getattr(sys.modules[__name__], name)()
        print(f"PTY isolated {name}: ok")
        return
    if os.environ.get("WTOP_PTY_ISOLATION") == "1":
        run_isolation()
        return
    profile = os.environ.get("WTOP_PTY_PROFILE", "full")
    if profile not in ("full", "quick"):
        raise SystemExit("WTOP_PTY_PROFILE must be 'full' or 'quick'")

    captures = []
    if profile == "quick":
        captures.append(run_session(80, 24, exercise=False))
        print("PTY 80x24 overview: ok")
        captures.append(run_session(180, 45, exercise=False, final_page=6))
        print("PTY 180x45 GPU page: ok")
        run_ascii_profile()
        print("PTY 100x30 ASCII/no-colour profile: ok")
        run_signal_shutdown()
        print("PTY signal shutdown: ok")
        assert any("进程".encode() in capture or "概览".encode() in capture for capture in captures), (
            "zh-CN catalog was not visible in the quick PTY profile"
        )
        assert any(LUA_BLUE_BACKGROUND in capture for capture in captures), (
            "default PTY profile did not emit the canonical Lua-blue background"
        )
        return

    run_responsive()
    run_cgroup_cross_link()
    print("PTY 160x45 workload to process cross-link: ok")
    run_cgroup_health()
    print("PTY 160x45 a healthy cgroup tree is not reported as partial: ok")
    run_gpu_client_drilldown()
    print("PTY 160x45 GPU client drill-down: ok")
    run_gpu_device_frequency()
    print("PTY 240x40 GPU device frequency is never zero: ok")
    run_gpu_device_clocks()
    print("PTY 160x45 a GPU device's own clock domains, side by side: ok")
    run_workspace_manager()
    print("PTY 160x45 workspace manager: ok")
    run_workspace_unicode_name()
    print("PTY 160x45 workspace name in a non-ASCII script, kept across a restart: ok")
    run_workspace_rename()
    print("PTY 160x45 workspace rename reaches the file: ok")
    run_layout_drop_target()
    print("PTY 160x45 layout drop target: ok")
    run_thread_drilldown()
    print("PTY 160x45 per-thread drill-down: ok")
    run_process_columns()
    print("PTY 160x45 process column editor: ok")
    run_process_columns_persistence()
    print("PTY 160x45 process column choice survives a restart: ok")
    run_process_queued_column()
    print("PTY 160x45 process run-queue column: ok")
    for page in range(2, 11):
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
    # Match the truecolour form specifically.  A bare ";2;" also matches the
    # SGR *dim* attribute, so the loose pattern failed the moment any widget
    # rendered dimmed text.
    assert not re.search(rb"(?:38|48);2;\d+;\d+;\d+", colour256), (
        "256-colour profile leaked truecolour SGR"
    )
    print("PTY 100x30 256-colour/light theme: ok")

    colour16 = run_session(
        100,
        30,
        exercise=False,
        terminal_environment={"TERM": "xterm", "COLORTERM": None},
        cli_options=("--theme", "colorblind", "--lang", "en-US"),
    )
    assert not re.search(rb"(?:38|48);2;\d+;\d+;\d+", colour16) and not re.search(
        rb"(?:38|48);5;\d+", colour16
    ), "16-colour profile emitted a higher colour depth"
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

    run_ascii_profile()
    print("PTY 100x30 ASCII/no-colour profile: ok")
    assert any("进程".encode() in capture or "概览".encode() in capture for capture in captures), (
        "zh-CN catalog was not visible in any PTY frame"
    )
    assert any(LUA_BLUE_BACKGROUND in capture for capture in captures), (
        "default PTY profile did not emit the canonical Lua-blue background"
    )


pty_smoke_module = sys.modules[__name__]


if __name__ == "__main__":
    main()
