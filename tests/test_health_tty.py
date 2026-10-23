#!/usr/bin/env python3
"""Exercise shared health warnings through the real offline TUI, with live-read guards."""
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
    with tempfile.TemporaryDirectory(prefix="wtop-health-tty-") as tmp:
        output = args.output_dir.resolve() if args.output_dir else Path(tmp)
        output.mkdir(parents=True, exist_ok=True)
        fixture = args.fixture.resolve() if args.fixture else output / "health.wtop"
        env = dict(os.environ, LUA_PATH=str(ROOT / "src/?.lua") + ";" + str(ROOT / "src/?/init.lua") + ";;",
            LUA_CPATH=str(ROOT / "build/native/?.so") + ";;")
        if not args.fixture:
            subprocess.run([str(args.lua.resolve()), str(ROOT / "tests/native/recording_fixture.lua"),
                str(fixture), "health"], cwd=ROOT, env=env, check=True, timeout=30)
        os.environ["WTOP_ROOT"] = str(ROOT)
        os.environ["WTOP_LUA"] = str(args.lua.resolve())
        if args.guard:
            assert not args.executable
            wrapper = output / "guarded-health"
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
            if not markers or not isinstance(markers[0], str) or not markers[0].startswith("health-"):
                return original(markers, data, columns, rows)
            screen = tty.VirtualScreen(columns, rows)
            screen.feed(bytes(data))
            text = screen.text()
            key = markers[0]
            title = "Health and warnings" in text or "健康与警报" in text
            active = ("Temperature threshold reached" in text or "达到温度阈值" in text)
            flags = "Sensor fault flag" in text or "传感器故障标志" in text
            quiet = "No warnings in current observations" in text or "当前观测中没有警报" in text
            unavailable = "Monitoring source unavailable" in text or "监测来源不可用" in text
            retained = "Monitoring source has retained data" in text or "监测来源正在保留旧数据" in text
            match = {
                "health-count": "!7" in text,
                "health-active": title and active and flags and "demo-sensor" in text,
                "health-quiet": title and quiet and not active and not flags,
                "health-stale": title and unavailable and retained and not active and not flags and not quiet,
                "health-tiny": title,
                "health-bottom": "Current observations only." in text,
            }.get(key, False)
            if match:
                screens[key + "-" + str(columns) + "-" + ("zh" if "健康与警报" in text else "en")] = text
            return match

        tty._markers_visible = visible
        try:
            for locale, ascii_mode in [("en-US", False), ("zh-CN", False), ("en-US", True)]:
                raw = tty.run_session(120, 36, exercise=False,
                    cli_options=("--replay", str(fixture), "--lang", locale, "--no-color"),
                    terminal_environment={"TERM": "dumb", "COLORTERM": None, "LANG": "C", "LC_ALL": "C"} if ascii_mode else None,
                    script=[(("sleep", .1), ("health-count",)), (b"!", None),
                        (("sleep", .1), ("health-active",)), (b"\x1b[1;3C", None),
                        (("sleep", .1), ("health-quiet",)), (b"\x1b[1;3C", None),
                        (("sleep", .1), ("health-stale",)), (b"\x1b[1;3H", None),
                        (("sleep", .1), ("health-active",)), (b"\x1b", None), (b"q", None)])
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
                script=[(b"!", None), (("sleep", .1), ("health-tiny",)),
                    (b"\x1b[F", None), (("sleep", .1), ("health-bottom",)), (b"\x1b", None), (b"q", None)])
            if args.guard:
                assert b"REPLAY_NO_LIVE_READS_PASSED" in raw
            (output / "tiny-40x10.pty").write_bytes(raw)
            receipts.append({"columns": 40, "rows": 10, "offline_guard": args.guard,
                "pty_sha256": hashlib.sha256(raw).hexdigest()})
        finally:
            tty._markers_visible = original
            (output / "screens.json").write_text(json.dumps(screens, ensure_ascii=False, indent=2) + "\n")
        (output / "health-TTY-acceptance.json").write_text(json.dumps({"status": "passed", "records": receipts}, indent=2) + "\n")
    print("HEALTH_TTY_PASSED: header count, EN/ZH/ASCII current/clear/stale warnings, rewind, tiny-terminal scroll and offline guards")


if __name__ == "__main__":
    main()
