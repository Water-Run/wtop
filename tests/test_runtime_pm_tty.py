#!/usr/bin/env python3
"""Device PM details through the real offline TUI, including live-read guards."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--lua", type=Path, default=ROOT / ".tools/lua-5.5.1/bin/lua")
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--guard", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="wtop-runtime-pm-") as tmp:
        output = args.output_dir.resolve() if args.output_dir else Path(tmp)
        output.mkdir(parents=True, exist_ok=True)
        fixture = args.fixture.resolve() if args.fixture else output / "runtime-pm.wtop"
        env = dict(os.environ, LUA_PATH=str(ROOT / "src/?.lua") + ";" + str(ROOT / "src/?/init.lua") + ";;",
            LUA_CPATH=str(ROOT / "build/native/?.so") + ";;")
        if not args.fixture:
            subprocess.run([str(args.lua.resolve()), str(ROOT / "tests/native/recording_fixture.lua"),
                str(fixture), "runtime-pm"], cwd=ROOT, env=env, check=True, timeout=30)
        os.environ.update(WTOP_ROOT=str(ROOT), WTOP_LUA=str(args.lua.resolve()))
        if args.guard:
            assert not args.executable
            wrapper = output / "guarded-runtime-pm"
            wrapper.write_text("#!/bin/sh\nexport LUA_PATH=" + shlex.quote(env["LUA_PATH"])
                + "\nexport LUA_CPATH=" + shlex.quote(env["LUA_CPATH"]) + "\nexec "
                + shlex.quote(str(args.lua.resolve())) + " "
                + shlex.quote(str(ROOT / "tests/native/replay_no_live.lua")) + ' "$@"\n')
            wrapper.chmod(0o700)
            os.environ["WTOP_EXECUTABLE"] = str(wrapper)
        elif args.executable:
            os.environ["WTOP_EXECUTABLE"] = str(args.executable.resolve())
        sys.path.insert(0, str(ROOT / "tests"))
        import pty_smoke as tty
        original = tty._markers_visible
        screens, receipts = {}, []

        def visible(markers, data, columns, rows):
            screen = tty.VirtualScreen(columns, rows)
            screen.feed(bytes(data))
            text = screen.text()
            title = "Device power management" in text or "设备电源管理" in text
            d0 = "Kernel PCI power state: D0" in text or "内核报告的 PCI 电源状态: D0" in text
            cold = "Kernel PCI power state: D3cold" in text or "内核报告的 PCI 电源状态: D3cold" in text
            suspended = "Runtime PM state: Suspended" in text or "运行时 PM 状态: 已暂停" in text
            stale = "Observation quality: Stale" in text or "观测质量: 已过期" in text
            if title and columns == 40:
                screens["runtime-pm-tiny-reachable"] = text
            if not markers or not isinstance(markers[0], str) or not markers[0].startswith("runtime-pm-"):
                return original(markers, data, columns, rows)
            key = markers[0]
            match = {"runtime-pm-d0": title and d0 and suspended and not cold,
                "runtime-pm-cold": title and cold and suspended,
                "runtime-pm-stale": title and stale,
                "runtime-pm-device": "Device:" in text,
                "runtime-pm-close": "Esc/Enter closes" in text,
            }.get(key, False)
            if match:
                screens[key + "-" + str(columns) + "-" + ("zh" if "设备电源管理" in text else "en")] = text
            return match

        tty._markers_visible = visible
        try:
            for locale, ascii_mode in [("en-US", False), ("zh-CN", False), ("en-US", True)]:
                raw = tty.run_session(120, 40, exercise=False,
                    cli_options=("--replay", str(fixture), "--lang", locale, "--no-color"),
                    terminal_environment={"TERM": "dumb", "COLORTERM": None, "LANG": "C", "LC_ALL": "C"} if ascii_mode else None,
                    script=[(b"9", None), (("sleep", .1), None),
                        (b"/0000:00:02.0\r", None), (b"\r", None),
                        (("sleep", .1), ("runtime-pm-d0",)), (b"\x1b[1;3C", None),
                        (("sleep", .1), ("runtime-pm-cold",)), (b"\x1b[1;3C", None),
                        (("sleep", .1), ("runtime-pm-stale",)), (b"\x1b[1;3H", None),
                        (("sleep", .1), ("runtime-pm-d0",)), (b"\x1b", None), (b"q", None)])
                if args.guard:
                    assert b"REPLAY_NO_LIVE_READS_PASSED" in raw
                if ascii_mode:
                    assert all(n < 128 for n in raw)
                name = locale + ("-ascii" if ascii_mode else "")
                (output / (name + ".pty")).write_bytes(raw)
                receipts.append({"locale": locale, "ascii": ascii_mode, "offline_guard": args.guard,
                    "pty_sha256": hashlib.sha256(raw).hexdigest()})
            raw = tty.run_session(40, 10, exercise=False,
                cli_options=("--replay", str(fixture), "--lang", "en-US", "--no-color"),
                script=[(b"9", None), (("sleep", .1), None),
                    (b"/0000:00:02.0\r", None), (b"\r", None),
                    (("sleep", .1), ("runtime-pm-device",))]
                    + [(b"\x1b[B", None) for _ in range(40)]
                    + [(b"\x1b[F", None), (("sleep", .1), ("runtime-pm-close",)), (b"\x1b", None), (b"q", None)])
            assert "runtime-pm-tiny-reachable" in screens, "PM title was unreachable in the tiny terminal"
            if args.guard:
                assert b"REPLAY_NO_LIVE_READS_PASSED" in raw
            (output / "tiny-40x10.pty").write_bytes(raw)
            receipts.append({"columns": 40, "rows": 10, "offline_guard": args.guard,
                "pty_sha256": hashlib.sha256(raw).hexdigest()})
        finally:
            tty._markers_visible = original
            (output / "screens.json").write_text(json.dumps(screens, ensure_ascii=False, indent=2) + "\n")
        (output / "runtime-pm-TTY-acceptance.json").write_text(json.dumps({"status": "passed", "records": receipts}, indent=2) + "\n")
    print("RUNTIME_PM_TTY_PASSED: EN/ZH/ASCII separate PCI/runtime states, D3cold transition, stale metadata, rewind, tiny scroll and offline guards")


if __name__ == "__main__":
    main()
