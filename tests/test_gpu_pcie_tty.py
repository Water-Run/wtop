#!/usr/bin/env python3
"""Check recorded PCIe readings, independent quality and the real GPU shortcut."""
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


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", type=Path, default=ROOT / ".tools/lua-5.5.1/bin/lua")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--guard", action="store_true")
    args = parser.parse_args()
    temporary = tempfile.TemporaryDirectory(prefix="wtop-pcie-replay-")
    output = args.output_dir.resolve() if args.output_dir else Path(temporary.name)
    if args.output_dir:
        output.mkdir(parents=True, exist_ok=False)
    lua = args.lua.resolve()
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
    env.update(LUA_PATH=str(ROOT / "src/?.lua") + ";" + str(ROOT / "src/?/init.lua") + ";;",
               LUA_CPATH=str(ROOT / "build/native/?.so") + ";;")
    fixture = output / "pcie.wtop"
    subprocess.run([str(lua), str(ROOT / "tests/native/recording_fixture.lua"), str(fixture), "gpu-pcie"],
                   cwd=ROOT, env=env, check=True, timeout=30)
    runner = ROOT / ("tests/native/replay_no_live.lua" if args.guard else "src/wtop.lua")
    cases = []
    for frame in range(1, 4):
        for mode in ["snapshot", "agent", "report"]:
            result = subprocess.run([str(lua), str(runner), "--replay", str(fixture), "--replay-frame", str(frame), "--" + mode],
                                    cwd=ROOT, env=env, capture_output=True, timeout=30)
            name = str(frame) + "-" + mode
            (output / (name + ".out")).write_bytes(result.stdout)
            (output / (name + ".stderr")).write_bytes(result.stderr)
            assert result.returncode == 0, (name, result.returncode)
            if args.guard:
                assert b"REPLAY_NO_LIVE_READS_PASSED" in result.stdout
            body = result.stdout.split(b"\nREPLAY_NO_LIVE_READS_PASSED")[0]
            if mode == "report":
                assert b"GPU PCIe links" in body and b"12345 (" + (b"fresh" if frame == 1 else b"stale") + b")" in body
            else:
                document = json.loads(body)
                gpu = document["gpus"]["devices"][0] if mode == "snapshot" else document["top"]["gpus"][0]
                assert gpu["metrics"]["pcie_tx_kilobytes_per_second"] == 12345
                assert gpu["metrics"]["pcie_rx_kilobytes_per_second"] == 0
                assert gpu["metrics"]["pcie_current_generation"] == 3 and gpu["metrics"]["pcie_maximum_width"] == 16
                if frame == 2:
                    assert gpu["metric_observations"]["pcie_tx_kilobytes_per_second"]["retained"]
                if mode == "agent":
                    from json_contract_smoke import validate
                    validate(document, "agent")
            cases.append({"frame": frame, "mode": mode, "actual_exit": result.returncode,
                          "SHA256": hashlib.sha256(result.stdout).hexdigest()})
    os.environ.update(WTOP_ROOT=str(ROOT), WTOP_LUA=str(lua))
    wrapper = output / "pcie-replay"
    wrapper.write_text("#!/bin/sh\nexport LUA_PATH=" + shlex.quote(env["LUA_PATH"]) + "\nexport LUA_CPATH="
                       + shlex.quote(env["LUA_CPATH"]) + "\nexec " + shlex.quote(str(lua)) + " "
                       + shlex.quote(str(runner)) + ' "$@"\n')
    wrapper.chmod(0o700)
    os.environ["WTOP_EXECUTABLE"] = str(wrapper)
    import pty_smoke as tty
    original, screens = tty._markers_visible, {}

    def visible(markers, data, columns, rows):
        if not markers or not isinstance(markers[0], str) or not markers[0].startswith("pcie-"):
            return original(markers, data, columns, rows)
        screen = tty.VirtualScreen(columns, rows)
        screen.feed(bytes(data))
        text, key = screen.text(), markers[0]
        tx = next((line for line in text.splitlines() if "PCIe TX" in line or "PCIe 发送" in line), "")
        rx = next((line for line in text.splitlines() if "PCIe RX" in line or "PCIe 接收" in line), "")
        def stale(value):
            return "stale" in value.lower() or "过期" in value
        match = "GPU PCIe" in text and "12345" in text.replace(",", "") and "0 KB/s" in rx and (
            key == "pcie-good" and "Gen3 x8" in text and "Gen4 x16" in text and not stale(tx)
            or key == "pcie-tx-stale" and stale(tx) and not stale(rx)
            or key == "pcie-source-stale" and stale(tx) and stale(rx))
        if match:
            screens[key + "-" + str(columns)] = text
        return match

    tty._markers_visible = visible
    try:
        for locale, columns, ascii_mode in [("en-US", 120, False), ("zh-CN", 100, False), ("en-US", 100, True)]:
            raw = tty.run_session(columns, 40, exercise=False,
                cli_options=("--replay", str(fixture), "--lang", locale, "--no-color"),
                script=[(b"7", None), (b"x", None), (("sleep", .1), ("pcie-good",)),
                        (b"\x1b[1;3C", None), (("sleep", .1), ("pcie-tx-stale",)),
                        (b"\x1b[1;3C", None), (("sleep", .1), ("pcie-source-stale",)), (b"\x1b", None), (b"q", None)],
                terminal_environment={"TERM": "dumb", "COLORTERM": None, "LANG": "C", "LC_ALL": "C", "LC_CTYPE": "C"} if ascii_mode else None)
            if args.guard:
                assert b"REPLAY_NO_LIVE_READS_PASSED" in raw
            if ascii_mode:
                assert all(byte < 128 for byte in raw)
            (output / (locale + ("-ascii" if ascii_mode else "") + ".pty")).write_bytes(raw)
            cases.append({"locale": locale, "ASCII": ascii_mode, "actual_exit": 0,
                          "guard": args.guard, "SHA256": hashlib.sha256(raw).hexdigest()})
    finally:
        tty._markers_visible = original
        (output / "screens.json").write_text(json.dumps(screens, ensure_ascii=False, indent=2) + "\n")
    (output / "acceptance.json").write_text(json.dumps({"status": "passed", "cases": cases}, indent=2) + "\n")
    print("GPU_PCIE_REPLAY_PASSED: nine exports and three EN/ZH/ASCII TTY sessions; guard=" + str(args.guard))
    temporary.cleanup()


if __name__ == "__main__":
    main()
