#!/usr/bin/env python3
"""Exercise the recording transport and offline exports of an actual program."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
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
    args = parser.parse_args()
    env = {k:v for k,v in os.environ.items()
        if not k.upper().startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
    if not args.executable:
        env["LUA_PATH"] = str(ROOT / "src/?.lua") + ";" + str(ROOT / "src/?/init.lua") + ";;"
        env["LUA_CPATH"] = str(ROOT / "build/native/?.so") + ";;"
    command = [str(args.executable.resolve())] if args.executable else [str(args.lua.resolve()), str(ROOT / "src/wtop.lua")]
    temporary = tempfile.TemporaryDirectory(prefix="wtop-recording-")
    output = args.output_dir.resolve() if args.output_dir else Path(temporary.name)
    output.mkdir(parents=True, exist_ok=True)
    env["XDG_CONFIG_HOME"] = str(output / "config")
    results = []

    def run(name: str, options: list[str], expected: int = 0) -> Path:
        path = output / name
        with path.open("wb") as stdout, (output / (name + ".stderr")).open("wb") as stderr:
            result = subprocess.run(command + options, cwd=ROOT, env=env, stdout=stdout, stderr=stderr, timeout=120)
        results.append({"case": name, "actual_exit": result.returncode,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
        if result.returncode != expected:
            sys.stderr.write((output / (name + ".stderr")).read_text(encoding="utf-8", errors="replace")[-8192:])
        assert result.returncode == expected, (name, result.returncode, expected)
        return path

    recording = run("actual-compressed.wtop", ["--record", "--count", "3", "--interval", "100", "--safe-mode"])
    content = recording.read_bytes()
    assert content.startswith(b"WTOPREC\0\1") and len(content) <= 256 * 1024 * 1024
    assert struct.unpack("<I", content[-12:-8])[0] == 0 and struct.unpack("<q", content[-8:])[0] == 3
    header_size = struct.unpack_from("<I", content, 9)[0]
    first = 9 + 8 + header_size
    assert content[first + 24] == 1, "the actual program did not use native LZ4 recording blocks"
    snapshots = []
    for frame in (1, 2, 3):
        path = run("frame-" + str(frame) + ".json", ["--replay", str(recording), "--replay-frame", str(frame), "--snapshot"])
        snapshot = json.loads(path.read_bytes())
        assert snapshot["observation"] == {**snapshot["observation"], "mode": "recorded", "frame": frame, "frames": 3, "complete": True}
        assert snapshot["schema"] == "dev.waterrun.wtop.snapshot/v1"
        snapshots.append(snapshot)
    assert snapshots[0]["captured_monotonic_ns"] < snapshots[1]["captured_monotonic_ns"] < snapshots[2]["captured_monotonic_ns"]
    agent_path = run("agent.json", ["--replay", str(recording), "--replay-frame", "2", "--agent"])
    agent = json.loads(agent_path.read_bytes())
    from json_contract_smoke import validate
    validate(agent, "agent")
    assert agent["observation"]["mode"] == "recorded" and agent["observation"]["frame"] == 2
    assert agent["captured_unix_ns"] == snapshots[1]["captured_unix_ns"] and agent["host"] == snapshots[1]["host"]
    # The same recorded frame must have identical source ages on every export.
    second = json.loads(run("frame-2-again.json", ["--replay", str(recording), "--replay-frame", "2", "--snapshot"]).read_bytes())
    assert second == snapshots[1]
    report = run("report.md", ["--replay", str(recording), "--report"]).read_text(encoding="utf-8")
    assert "> Recorded measurement: frame 1/3." in report and "# wtop hardware report" in report
    partial = output / "interrupted.wtop"
    partial.write_bytes(content[:-7])
    recovered = json.loads(run("interrupted.json", ["--replay", str(partial), "--replay-frame", "3", "--snapshot"]).read_bytes())
    assert not recovered["observation"]["complete"] and recovered["captured_unix_ns"] == snapshots[2]["captured_unix_ns"]
    corrupt = bytearray(content)
    corrupt[first + 24 + 6] ^= 1
    damaged = output / "damaged.wtop"
    damaged.write_bytes(corrupt)
    run("damaged.out", ["--replay", str(damaged), "--snapshot"], expected=1)
    run("outside.out", ["--replay", str(recording), "--replay-frame", "4", "--snapshot"], expected=1)
    if hasattr(os, "mkfifo"):
        fifo = output / "not-a-recording.fifo"
        os.mkfifo(fifo)
        try:
            run("fifo.out", ["--replay", str(fifo), "--snapshot"], expected=1)
        finally:
            fifo.unlink()
    receipt = {"status": "passed", "recorded_frames": 3, "native_LZ4": True,
        "CLI_modes": ["record", "replay snapshot", "replay agent", "replay report"],
        "recorded_bytes": len(content), "cases": results}
    (output / "recording-acceptance.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("RECORDING_APPLICATION_PASSED: native binary transport/LZ4, 3 full frames, exact historical exports, interrupted footer, corrupt/out-of-range rejection")
    temporary.cleanup()


if __name__ == "__main__":
    main()
