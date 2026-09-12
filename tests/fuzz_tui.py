#!/usr/bin/env python3
"""Throw random input at the real terminal loop and assert it never dies badly.

The scripted PTY cases in `pty_smoke.py` walk paths someone thought of.  This
walks paths nobody thought of: arbitrary key order, mouse reports at arbitrary
coordinates, bracketed paste, half-written escape sequences, invalid UTF-8, NUL
bytes, and window resizes in the middle of all of it.

A run is a failure when the child dies from a signal, exits non-zero, prints a
Lua traceback, or fails to exit at all.  Anything else — including wtop
rejecting the input — is a pass: the contract is that no input sequence can
crash the process or leave the terminal unrestored.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import pathlib
import pty
import random
import re
import select
import signal
import struct
import sys
import termios
import time

ROOT = pathlib.Path(os.environ.get("WTOP_ROOT", pathlib.Path(__file__).resolve().parents[1]))
LUA = os.environ.get("WTOP_LUA", str(ROOT / ".tools/lua-5.5.1/bin/lua"))
EXECUTABLE = os.environ.get("WTOP_EXECUTABLE")

# Every binding the UI defines, plus input it must survive without defining.
INPUTS = [
    b"1", b"2", b"3", b"4", b"5", b"6", b"7", b"8", b"9", b"0",
    b"\x1b[A", b"\x1b[B", b"\x1b[C", b"\x1b[D", b"\x1b[5~", b"\x1b[6~",
    b"\x1b[H", b"\x1b[F", b"\x1b[3~", b"\t", b"\x1b[Z",
    b"/", b"o", b"O", b"t", b"p", b"e", b"v", b"T", b"L", b"?", b"\x1bOP",
    b"\r", b"\x1b", b"k", b"s", b"b", b"d", b"f", b" ", b"r", b"\x0c",
    b"u", b"U", b"[", b"]", b"\x7f", b"\x17", b"\x15", b"\x0b", b"\x01", b"\x05",
    b"y", b"n", b"x", b"Z", b"!", b":", b"~", b"q",
    # Query fragments, including a deliberately malformed Lua pattern.
    b"user:root", b"state:D", b"!kernel", b"/^sys", b"/[unclosed", b"\xe4\xb8\xad",
    # SGR mouse: press, release, wheel up/down, and coordinates outside any panel.
    b"\x1b[<0;5;1M", b"\x1b[<0;5;1m", b"\x1b[<64;20;10M", b"\x1b[<65;20;10M",
    b"\x1b[<0;30;5M", b"\x1b[<0;10;24M", b"\x1b[<0;999;999M",
    b"\x1b[200~pasted\ttext\x1b[201~",
    # Input the decoder must reject rather than mis-frame.
    b"\x1b", b"\x1b[", b"\x1b[99999;99999R", b"\xff\xfe", b"\x00", b"\x1b]0;t\x07",
]

SIZES = [(40, 10), (80, 24), (100, 30), (60, 16), (160, 45), (25, 8), (200, 20)]
LOCALES = ["en-US", "zh-CN", "ja-JP", "de-DE", "ru-RU"]

TRACEBACK = re.compile(rb"stack traceback|attempt to (?:index|call|perform)|\.lua:\d+: ")


def run_case(seed: int, steps: int, config_home: str) -> tuple[str, int, int, bytes]:
    rng = random.Random(seed)
    columns, rows = rng.choice(SIZES)
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
        environment.pop("NO_COLOR", None)
        environment["XDG_CONFIG_HOME"] = config_home
        arguments = ["--interval", "200", "--lang", rng.choice(LOCALES)]
        if EXECUTABLE:
            os.execve(EXECUTABLE, [EXECUTABLE, *arguments], environment)
        os.execve(LUA, [LUA, str(ROOT / "src/wtop.lua"), *arguments], environment)

    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
    os.set_blocking(master, False)
    output = bytearray()
    deadline = time.monotonic() + 45.0
    next_at = time.monotonic() + 1.5
    sent = 0
    status = None

    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.02)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                # The child closed the pty; collect its real status rather than
                # reporting the EOF itself as a hang.
                _, status = os.waitpid(pid, 0)
                break
            output.extend(chunk)

        now = time.monotonic()
        if sent < steps and now >= next_at:
            if rng.random() < 0.12:
                new_columns, new_rows = rng.choice(SIZES)
                fcntl.ioctl(master, termios.TIOCSWINSZ,
                            struct.pack("HHHH", new_rows, new_columns, 0, 0))
                os.kill(pid, signal.SIGWINCH)
            else:
                try:
                    os.write(master, rng.choice(INPUTS))
                except OSError:
                    break
            sent += 1
            next_at = now + 0.045
        elif sent == steps:
            # Exactly one interrupt.  Repeating it races the shutdown and kills
            # the process after it has already restored the terminal.
            try:
                os.write(master, b"\x03")
            except OSError:
                pass
            sent = steps + 1

        waited, wait_status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            status = wait_status
            break

    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        os.close(master)
        return "did-not-exit", columns, rows, bytes(output)[-2000:]
    os.close(master)

    text = bytes(output)
    if TRACEBACK.search(text):
        return "lua-error", columns, rows, text[-3000:]
    if os.WIFSIGNALED(status):
        return f"killed-by-signal-{os.WTERMSIG(status)}", columns, rows, text[-2000:]
    if os.WEXITSTATUS(status) != 0:
        return f"exit-{os.WEXITSTATUS(status)}", columns, rows, text[-2000:]
    # The alternate screen must always be left, however the session ended.
    if b"\x1b[?1049h" in text and b"\x1b[?1049l" not in text:
        return "terminal-not-restored", columns, rows, text[-2000:]
    return "ok", columns, rows, b""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seeds", type=int, default=20, help="number of random sessions")
    parser.add_argument("--first-seed", type=int, default=1)
    parser.add_argument("--steps", type=int, default=70, help="inputs per session")
    arguments = parser.parse_args()

    config_home = str(ROOT / ".tools/fuzz-config")
    os.makedirs(config_home, exist_ok=True)

    failures = 0
    for seed in range(arguments.first_seed, arguments.first_seed + arguments.seeds):
        verdict, columns, rows, tail = run_case(seed, arguments.steps, config_home)
        print(f"fuzz seed {seed} {columns}x{rows}: {verdict}", flush=True)
        if verdict != "ok":
            failures += 1
            sys.stderr.write(tail.decode("utf-8", "replace") + "\n")
    print(f"fuzz: {arguments.seeds - failures}/{arguments.seeds} sessions clean")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
