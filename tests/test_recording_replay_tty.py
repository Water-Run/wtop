#!/usr/bin/env python3
"""Real TTY replay: historical power bars, timeline controls and offline guards."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--lua", type=Path, default=ROOT / ".tools/lua-5.5.1/bin/lua")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--guard", action="store_true")
    args = parser.parse_args()
    temporary = tempfile.TemporaryDirectory(prefix="wtop-replay-tty-")
    output = args.output_dir.resolve() if args.output_dir else Path(temporary.name)
    output.mkdir(parents=True, exist_ok=True)
    fixture = args.fixture.resolve() if args.fixture else output / "power.wtop"
    env = os.environ.copy()
    env["LUA_PATH"] = str(ROOT / "src/?.lua") + ";" + str(ROOT / "src/?/init.lua") + ";;"
    env["LUA_CPATH"] = str(ROOT / "build/native/?.so") + ";;"
    if not args.fixture:
        subprocess.run([str(args.lua.resolve()), str(ROOT / "tests/native/recording_fixture.lua"), str(fixture)],
            cwd=ROOT, env=env, check=True, timeout=30)
    os.environ["WTOP_ROOT"] = str(ROOT)
    os.environ["WTOP_LUA"] = str(args.lua.resolve())
    if args.guard:
        assert not args.executable, "the source guard instruments the source runner"
        wrapper = output / "guarded-replay"
        import shlex
        wrapper.write_text("#!/bin/sh\nexport LUA_PATH=" + shlex.quote(env["LUA_PATH"]) + "\nexport LUA_CPATH="
            + shlex.quote(env["LUA_CPATH"]) + "\nexec " + shlex.quote(str(args.lua.resolve())) + " "
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
        if not markers or not isinstance(markers[0], str) or not markers[0].startswith("replay-"):
            return original(markers, data, columns, rows)
        screen = tty.VirtualScreen(columns, rows)
        screen.feed(bytes(data))
        text = screen.text()
        key = markers[0]
        match = {
            "replay-50": "50%" in text and "20 W" in text,
            "replay-90": "90%" in text and "20 W" in text,
            "replay-stale": "90%" not in text and "50%" not in text and ("stale" in text.lower() or "过期" in text),
            "replay-process": "recorded-demo" in text,
            "replay-offline": "Live inspection" in text or "回放期间不执行" in text,
            "replay-last": "3/3" in text,
            "replay-first": "1/3" in text,
            "replay-eof-paused": "SpaceResume" in "".join(text.split()),
        }.get(key, False)
        if match: screens[key + "-" + str(columns)] = text
        return match

    tty._markers_visible = visible
    try:
        for locale, columns, rows, ascii_mode in [("en-US",120,40,False), ("zh-CN",100,30,False), ("en-US",100,30,True)]:
            script = [(b"p", None), (("sleep", .1), ("replay-50",)),
                (b"\x1b[1;3C", None), (("sleep", .1), ("replay-90",)),
                (b"\x1b[1;3C", None), (("sleep", .1), ("replay-stale",)),
                (b"\x1b[1;3H", None), (("sleep", .1), ("replay-50",)),
                (b"\x1b", None), (b"2", None), (("sleep", .1), ("replay-process",)),
                (b"k", None), (("sleep", .1), ("replay-offline",)),
                (b"\r", None), (b"F", None), (b"\x1b", None),
                (b"s", None), (("sleep", .1), ("replay-offline",)), (b"\x1b", None),
                (b"1", None), (b" ", None), (("sleep", 2.4), ("replay-last",)),
                (b"\x1b[1;3H", None), (("sleep", .1), ("replay-first",)), (b"f", None), (b"q", None)]
            environment = {"TERM":"dumb","COLORTERM":None,"LANG":"C","LC_ALL":"C","LC_CTYPE":"C"} if ascii_mode else None
            raw = tty.run_session(columns, rows, exercise=False,
                cli_options=("--replay", str(fixture), "--lang", locale, "--no-color"),
                script=script, terminal_environment=environment)
            if args.guard: assert b"REPLAY_NO_LIVE_READS_PASSED" in raw
            if ascii_mode: assert all(n < 128 for n in raw)
            name = locale + ("-ascii" if ascii_mode else "")
            (output / (name + ".pty")).write_bytes(raw)
            receipts.append({"locale":locale,"ascii":ascii_mode,"offline_guard":args.guard,
                "pty_sha256":hashlib.sha256(raw).hexdigest()})
        raw = tty.run_session(40, 10, exercise=False,
            cli_options=("--replay",str(fixture),"--lang","en-US","--no-color"),
            script=[(("sleep",.1),("replay-first",)), (b"\x1b[1;3F",None),
                (("sleep",.1),("replay-last",)), (b"\x1b[1;3H",None),
                (("sleep",.1),("replay-first",)), (b"q",None)])
        if args.guard: assert b"REPLAY_NO_LIVE_READS_PASSED" in raw
        (output / "tiny-40x10.pty").write_bytes(raw)
        receipts.append({"columns":40,"rows":10,"offline_guard":args.guard,
            "pty_sha256":hashlib.sha256(raw).hexdigest()})
        raw = tty.run_session(140, 40, exercise=False,
            cli_options=("--replay",str(fixture),"--replay-frame","3","--lang","en-US","--no-color"),
            script=[(("sleep",.1),("replay-eof-paused",)),(b" ",None),
                (("sleep",.2),("replay-eof-paused",)),(b"q",None)])
        if args.guard: assert b"REPLAY_NO_LIVE_READS_PASSED" in raw
        (output / "eof-pause.pty").write_bytes(raw)
        receipts.append({"eof_remains_paused":True,"offline_guard":args.guard,
            "pty_sha256":hashlib.sha256(raw).hexdigest()})
    finally:
        tty._markers_visible = original
        (output / "screens.json").write_text(json.dumps(screens,ensure_ascii=False,indent=2)+"\n")
    (output / "screens.json").write_text(json.dumps(screens,ensure_ascii=False,indent=2)+"\n")
    (output / "TTY-acceptance.json").write_text(json.dumps({"status":"passed","records":receipts},indent=2)+"\n")
    print("RECORDING_TTY_PASSED: EN/ZH/ASCII historical 50%/90% bars and stale withdrawal, pause/play/step/seek/speed, process/detail and offline inspection guards")
    temporary.cleanup()


if __name__ == "__main__":
    main()
