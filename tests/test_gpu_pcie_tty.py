#!/usr/bin/env python3
"""Check recorded PCIe readings, independent quality and the real GPU shortcut."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
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
    parser.add_argument("--executable", type=Path, help="check an existing development bundle")
    parser.add_argument("--recording", type=Path, help="use an existing PCIe fixture without a source Lua runtime")
    parser.add_argument("--cli-only", action="store_true", help="check nine exports without POSIX terminal APIs")
    args = parser.parse_args()
    if args.guard and args.executable:
        parser.error("--guard instruments source Lua; use the source run separately from the bundle check")
    if args.executable and not args.executable.is_file():
        parser.error("--executable must name an existing bundle entry")
    if not args.recording and not args.lua.is_file():
        parser.error("--lua must name an interpreter when no --recording is supplied")
    temporary = tempfile.TemporaryDirectory(prefix="wtop-pcie-replay-")
    output = args.output_dir.resolve() if args.output_dir else Path(temporary.name)
    if args.output_dir:
        output.mkdir(parents=True, exist_ok=False)
    lua = args.lua.resolve()
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
    source_env = dict(env, LUA_PATH=str(ROOT / "src/?.lua") + ";" + str(ROOT / "src/?/init.lua") + ";;",
                      LUA_CPATH=str(ROOT / "build/native/?.so") + ";;")
    fixture = output / "pcie.wtop"
    if args.recording:
        shutil.copyfile(args.recording, fixture)
    else:
        subprocess.run([str(lua), str(ROOT / "tests/native/recording_fixture.lua"), str(fixture), "gpu-pcie"],
                       cwd=ROOT, env=source_env, check=True, timeout=30)
    runner = ROOT / ("tests/native/replay_no_live.lua" if args.guard else "src/wtop.lua")
    command = [str(args.executable.resolve())] if args.executable else [str(lua), str(runner)]
    if not args.executable:
        env = source_env
    cases = []
    def receipt():
        document = {"status": "passed", "cases": cases, "guard": args.guard,
                    "fixture_SHA256": hashlib.sha256(fixture.read_bytes()).hexdigest()}
        if args.executable:
            document.update(executable=str(args.executable.resolve()),
                            entry_SHA256=hashlib.sha256(args.executable.read_bytes()).hexdigest())
        (output / "acceptance.json").write_text(json.dumps(document, indent=2) + "\n")
    for frame in range(1, 4):
        for mode in ["snapshot", "agent", "report"]:
            result = subprocess.run(command + ["--replay", str(fixture), "--replay-frame", str(frame), "--" + mode],
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
                assert b"GPU OS PCIe links" in body and b"5.0 GT/s PCIe" in body and b"16.0 GT/s PCIe" in body
            else:
                document = json.loads(body)
                gpu = document["gpus"]["devices"][0] if mode == "snapshot" else document["top"]["gpus"][0]
                assert gpu["metrics"]["pcie_tx_kilobytes_per_second"] == 12345
                assert gpu["metrics"]["pcie_rx_kilobytes_per_second"] == 0
                assert gpu["metrics"]["pcie_current_generation"] == 3 and gpu["metrics"]["pcie_maximum_width"] == 16
                assert gpu["pci"]["current_link_width"] == 4 and gpu["pci"]["maximum_link_speed"] == "16.0 GT/s PCIe"
                devices = document["gpus"]["devices"] if mode == "snapshot" else document["top"]["gpus"]
                os_gpu = next(device for device in devices if device["card"] == "card1")
                assert os_gpu["pci"]["current_link_width"] == 2 and not os_gpu["metrics"].get("pcie_current_generation")
                if frame == 2:
                    assert gpu["metric_observations"]["pcie_tx_kilobytes_per_second"]["retained"]
                    assert gpu["observations"]["drm"]["retained"] and gpu["observations"]["drm"]["observed_at_ns"] == 1000000000
                if mode == "agent":
                    from json_contract_smoke import validate
                    validate(document, "agent")
            cases.append({"frame": frame, "mode": mode, "actual_exit": result.returncode,
                          "SHA256": hashlib.sha256(result.stdout).hexdigest()})
    if args.cli_only:
        receipt()
        print("GPU_PCIE_CLI_PASSED: nine exports; bundle=" + str(bool(args.executable)))
        temporary.cleanup()
        return
    os.environ.update(WTOP_ROOT=str(ROOT), WTOP_LUA=str(lua))
    wrapper = output / "pcie-replay"
    exports = "" if args.executable else ("export LUA_PATH=" + shlex.quote(env["LUA_PATH"])
        + "\nexport LUA_CPATH=" + shlex.quote(env["LUA_CPATH"]) + "\n")
    if args.executable:
        for key in list(os.environ):
            if key.upper().startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT")):
                del os.environ[key]
    wrapper.write_text("#!/bin/sh\n" + exports + "exec " + shlex.join(command) + ' "$@"\n')
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
        if key.startswith("pcie-main-"):
            screens["observed-" + key + "-" + str(columns)] = text
            headers = next((cells for cells in screen.characters if "PCIe" in "".join(cells) and "Card" in "".join(cells)), [])
            start = next((index for index in range(len(headers) - 3) if "".join(headers[index:index + 4]) == "PCIe"), None)
            row = next((cells for cells in screen.characters if "card0" in "".join(cells)), [])
            # A narrow PCIe cell prioritizes the quality prefix and can clip
            # its numeric suffix. Check that cell in terminal coordinates.
            cell = "".join(row[start:start + 9]) if start is not None else ""
            stale = "stale" in cell.lower() or "过期" in cell
            match = bool(cell) and (stale if key != "pcie-main-fresh" else "8.0" in cell and not stale)
            if match:
                screens[key + "-" + str(columns)] = text
            return match
        if key == "pcie-os-only":
            match = "Recorded OS-only GPU" in text and "5.0 GT/s PCIe x2" in text and "8.0 GT/s PCIe x4" in text
            if match:
                screens[key + "-" + str(columns)] = text
            return match
        tx = next((line for line in text.splitlines() if "PCIe TX" in line or "PCIe 发送" in line), "")
        rx = next((line for line in text.splitlines() if "PCIe RX" in line or "PCIe 接收" in line), "")
        os_link = next((line for line in text.splitlines() if "OS current link" in line or "系统当前链路" in line), "")
        def stale(value):
            return "stale" in value.lower() or "过期" in value
        match = "GPU PCIe" in text and "8.0 GT/s PCIe x4" in os_link and "12345" in text.replace(",", "") and "0 KB/s" in rx and (
            key == "pcie-good" and "Gen3 x8" in text and "Gen4 x16" in text and not stale(tx) and not stale(os_link)
            or key == "pcie-tx-stale" and stale(tx) and not stale(rx) and stale(os_link)
            or key == "pcie-source-stale" and stale(tx) and stale(rx) and stale(os_link))
        if match:
            screens[key + "-" + str(columns)] = text
        return match

    tty._markers_visible = visible
    try:
        for locale, columns, ascii_mode in [("en-US", 120, False), ("zh-CN", 100, False), ("en-US", 100, True)]:
            raw = tty.run_session(columns, 40, exercise=False,
                cli_options=("--replay", str(fixture), "--lang", locale, "--no-color"),
                script=[(b"7", None), (b"x", None), (("sleep", .1), ("pcie-good",)),
                        (b"\x1b[6~", None), (("sleep", .1), ("pcie-os-only",)), (b"\x1b[5~", None),
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
        for locale in ["en-US", "zh-CN"]:
            raw = tty.run_session(240, 40, exercise=False,
                cli_options=("--replay", str(fixture), "--lang", locale, "--no-color"),
                script=[(b"7", None), (("sleep", .1), ("pcie-main-fresh",)),
                        (b"\x1b[1;3C", None), (("sleep", .1), ("pcie-main-retained",)),
                        (b"\x1b[1;3C", None), (("sleep", .1), ("pcie-main-source-stale",)), (b"q", None)])
            if args.guard:
                assert b"REPLAY_NO_LIVE_READS_PASSED" in raw
            (output / (locale + "-main.pty")).write_bytes(raw)
            cases.append({"locale": locale, "columns": 240, "main_table": True, "actual_exit": 0,
                          "guard": args.guard, "SHA256": hashlib.sha256(raw).hexdigest()})
    finally:
        tty._markers_visible = original
        (output / "screens.json").write_text(json.dumps(screens, ensure_ascii=False, indent=2) + "\n")
    receipt()
    print("GPU_PCIE_REPLAY_PASSED: nine exports, three EN/ZH/ASCII detail and two EN/ZH main-table TTY sessions; guard=" + str(args.guard))
    temporary.cleanup()


if __name__ == "__main__":
    main()
