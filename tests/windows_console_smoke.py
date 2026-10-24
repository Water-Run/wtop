#!/usr/bin/env python3
"""Exercise an installed Windows program through a real console screen buffer."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


GPU_LAYOUT = '''schema_version: 5
pages:
  gpu:
    type: leaf
    widget_id: "gpu_table"
process_columns:
  - "pid"
  - "name"
tabs:
  - "gpu"
removed_widgets:
  gpu:
    - "gpu_summary"
    - "gpu_process_table"
'''


def validate_gpu_capture(data: bytes, actual_exit: int, page: int, locale: str, frame: int) -> dict:
    name = str(page) + "-" + locale + "-" + str(frame)
    output = data.decode("utf-8", errors="replace").replace("\r\n", "\n")
    assert actual_exit == 0, (name, output[-6000:])
    assert "process exited, exit code 0" in output and "terminated a process" not in output, name
    assert "\x1b" not in output, name
    assert "code page " + str(page) in output and "resize 100x30 buffer=1 window=1" in output, name
    screens = {key: screen for key, screen in re.findall(
        r"^===== (\w+) [^\n]+\n(.*?)(?=^-----|\Z)", output, re.M | re.S)}
    header = next(line for line in screens["gpu_main"].splitlines() if "PCIe" in line and "Card" in line)
    row = next(line for line in screens["gpu_main"].splitlines() if "card0" in line)
    # ReadConsoleOutputA records one byte per cell. Re-encode the
    # decoded screenshot to recover CP936's two-cell characters.
    column = header.encode("cp" + str(page), errors="replace").index(b"PCIe")
    cell = row.encode("cp" + str(page), errors="replace")[column:column + 9]
    stale_word = "过期" if locale == "zh-CN" else "Stale"
    assert (stale_word.encode("cp" + str(page)) in cell) == (frame > 1), (name, cell)
    if frame == 1:
        assert b"8.0" in cell, (name, cell)
    detail = screens["gpu_detail"]
    labels = ["PCIe TX", "PCIe RX", "OS current link"] if locale == "en-US" else ["PCIe 发送", "PCIe 接收", "系统当前链路"]
    lines = [next(line for line in detail.splitlines() if label in line) for label in labels]
    assert (stale_word in lines[0]) == (frame > 1), (name, lines[0])
    assert (stale_word in lines[1]) == (frame == 3), (name, lines[1])
    assert (stale_word in lines[2]) == (frame > 1), (name, lines[2])
    assert "12345" in lines[0].replace(",", "") and "0 KB/s" in lines[1], name
    assert "Recorded OS-only GPU" in screens["gpu_os"] and "5.0 GT/s PCIe x2" in screens["gpu_os"], name
    return screens


def run_gpu_replay(executable: Path, harness: Path, recording: Path, output_dir: Path | None = None) -> None:
    """Use the synthetic gpu-pcie fixture in a private, single-panel layout."""
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
    with tempfile.TemporaryDirectory(prefix="wtop-gpu-console-") as temporary:
        root = Path(temporary)
        environment.update(APPDATA=str(root), TERM="dumb")
        layout = root / "gpu-layout.yml"
        layout.write_text(GPU_LAYOUT, encoding="utf-8")
        imported = subprocess.run([str(executable.resolve()), "--import-layout", str(layout)],
                                  env=environment, cwd=root, capture_output=True, timeout=30)
        assert imported.returncode == 0, imported.stderr.decode(errors="replace")
        receipts = []
        if output_dir:
            output_dir.mkdir(parents=True, exist_ok=False)
        for page, locale in [(437, "en-US"), (936, "en-US"), (936, "zh-CN")]:
            environment["WTOP_TEST_CONSOLE_CODEPAGE"] = str(page)
            for frame in range(1, 4):
                command = subprocess.list2cmdline([str(executable.resolve()), "--replay", str(recording.resolve()),
                    "--replay-frame", str(frame), "--lang", locale, "--no-color"])
                steps = ("resize:100x30,capture:15000:gpu_main:PCIe|card0,key:x,"
                         "capture:10000:gpu_detail:GPU PCIe|8.0 GT/s PCIe x4|KB/s,"
                         "vk:34,capture:10000:gpu_os:Recorded OS-only GPU|5.0 GT/s PCIe x2,"
                         "key:\\e,key:q,exit:10000")
                result = subprocess.run([str(harness.resolve()), steps, command], env=environment,
                                        cwd=root, capture_output=True, timeout=60)
                name = str(page) + "-" + locale + "-" + str(frame)
                if output_dir:
                    (output_dir / (name + ".out")).write_bytes(result.stdout)
                    (output_dir / (name + ".stderr")).write_bytes(result.stderr)
                validate_gpu_capture(result.stdout, result.returncode, page, locale, frame)
                receipts.append({"code_page": page, "locale": locale, "frame": frame,
                    "actual_exit": result.returncode, "SHA256": hashlib.sha256(result.stdout).hexdigest()})
                print("Windows classic GPU replay " + name + ": ok")
        if output_dir:
            (output_dir / "acceptance.json").write_text(json.dumps({"status": "passed", "cases": receipts,
                "entry_SHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                "recording_SHA256": hashlib.sha256(recording.read_bytes()).hexdigest()}, indent=2) + "\n")


def run(executable: Path, harness: Path) -> None:
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
    with tempfile.TemporaryDirectory(prefix="wtop-console-") as temporary:
        environment["APPDATA"] = temporary
        environment["TERM"] = "dumb"
        command = subprocess.list2cmdline([str(executable.resolve()), "--lang", "en-US", "--no-color"])
        # The Host tile can be below the visible Overview panels at 80x25.
        # Memory is part of the default visible layout on every tested host.
        steps = ("capture:20000:overview:CPU|Memory,key:2,capture:10000:processes:PID|Command,"
                 "resize:100x30,key:6,capture:10000:network:Interfaces|Sockets,"
                 "key:9,capture:10000:system:Host|Kernel,key:q,exit:10000")
        result = subprocess.run([str(harness.resolve()), steps, command], env=environment,
                                cwd=temporary, capture_output=True, timeout=75)
        output = result.stdout.decode("utf-8", errors="replace").replace("\r\n", "\n")
        assert result.returncode == 0, output + result.stderr.decode(errors="replace")
        assert "process exited, exit code 0" in output, output
        assert "terminated a process" not in output and "\x1b" not in output, output
        screens = {name: screen for name, screen in re.findall(
            r"^===== (\w+) [^\n]+\n(.*?)(?=^-----|\Z)", output, re.M | re.S)}
        for name, markers in {"overview": ("CPU", "Memory"), "processes": ("PID", "Command"),
                              "network": ("Interfaces", "Sockets"), "system": ("Host", "Kernel")}.items():
            assert all(marker in screens.get(name, "") for marker in markers), output
            print("Windows console " + name + ": ok")
        print("Windows console resize and clean exit: ok")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--gpu-recording", type=Path, help="also check the synthetic PCIe fixture in classic consoles")
    parser.add_argument("--gpu-output-dir", type=Path, help="save the recorded GPU console screens and receipt")
    args = parser.parse_args()
    run(args.executable, args.harness)
    if args.gpu_recording:
        run_gpu_replay(args.executable, args.harness, args.gpu_recording, args.gpu_output_dir)
