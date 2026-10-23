#!/usr/bin/env python3
"""Build/run isolated storage API delay proofs; never modify production runtime."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def build(runtime: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=False)
    flags = ["-std=c17", "-O2", "-Wall", "-Wextra", "-Werror", "-static-libgcc",
             "-I" + str(runtime / "include"), "-I" + str(ROOT / "build/native"),
             "-I" + str(ROOT / "build/windows-x86")]
    units = [ROOT / "native" / name for name in [
        "wtop_windows.c", "wtop_windows_net.c", "wtop_windows_hw.c",
        "wtop_windows_cpu.c", "wtop_windows_cpuid.c", "wtop_windows_worker.c"]]
    subprocess.run(["i686-w64-mingw32-gcc", *flags, "-shared", *map(str, units),
                    str(ROOT / "tests/native/windows_storage_blocked.c"),
                    str(runtime / "liblua55.dll.a"), "-lpsapi", "-liphlpapi", "-lsetupapi",
                    "-o", str(output / "wtop_native.dll")], check=True)
    subprocess.run(["i686-w64-mingw32-gcc", *flags,
                    str(ROOT / "tests/native/windows_process_reaped.c"),
                    "-o", str(output / "process-reaped.exe")], check=True)
    for name in ["lua.exe", "lua55.dll"]:
        shutil.copyfile(runtime / name, output / name)
    shutil.copytree(ROOT / "src", output / "src")
    shutil.copyfile(ROOT / "tests/native/windows_storage_lifecycle.lua",
                    output / "storage_lifecycle.lua")
    with zipfile.ZipFile(output.with_suffix(".zip"), "x", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(output.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(output).as_posix())
    print("Windows storage lifecycle fixture archive built", flush=True)


def run(folder: Path) -> None:
    assert os.name == "nt", "execute storage API proofs on Windows"
    results = []
    for target in ["health", "disk"]:
        for mode in ["direct", "warm", "quit"]:
            case = folder / (target + "-" + mode)
            case.mkdir(exist_ok=False)
            profile = case / "profile"
            profile.mkdir()
            env = {**os.environ, "APPDATA": str(profile),
                   "LUA_PATH": str(folder / "src/?.lua") + ";" + str(folder / "src/?/init.lua") + ";;",
                   "LUA_CPATH": str(folder / "?.dll") + ";;",
                   "WTOP_STORAGE_FAULT_ROOT": str(case), "WTOP_STORAGE_FAULT_TARGET": target,
                   "WTOP_STORAGE_FAULT_DIRECT": "1" if mode == "direct" else "0",
                   "WTOP_STORAGE_ALLOW_UNAVAILABLE": "1",
                   "WTOP_STORAGE_COLD_ONCE": "1" if mode == "warm" else "0"}
            started = time.monotonic()
            result = subprocess.run([str(folder / "lua.exe"), "storage_lifecycle.lua", mode],
                                    cwd=folder, env=env, capture_output=True, timeout=45)
            (case / "parent.log").write_bytes(result.stdout + result.stderr)
            if result.returncode != (19 if mode == "quit" else 0):
                sys.stderr.write((case / "parent.log").read_text(encoding="utf-8", errors="replace")[-8192:])
            assert result.returncode == (19 if mode == "quit" else 0), case / "parent.log"
            if mode == "warm":
                proof = json.loads((case / "result.json").read_text())
                assert all(proof[key] for key in ["retained_timestamp", "healthy_sources_advance",
                                                  "reaped_before_lease", "new_reader_recovered",
                                                  "cold_start_timeout_recovered"])
            elif mode == "quit":
                marker = json.loads((case / (target + ".blocked")).read_text())
                assert isinstance(marker["birth"], str) and marker["birth"].isdigit()
                checked = subprocess.run([str(folder / "process-reaped.exe"), str(marker["pid"]),
                                          marker["birth"], "1000"], cwd=folder,
                                         capture_output=True, timeout=5)
                (case / "reap.log").write_bytes(checked.stdout + checked.stderr)
                checked.check_returncode()
                elapsed = time.monotonic() - started
                assert elapsed < 9, (case, elapsed)
                proof = {"parent_start_to_reap_seconds": elapsed, "reaped_before_lease": True}
            else:
                assert b"direct baseline ms" in result.stdout
                proof = {"baseline_seconds_at_least": 9.9}
            results.append({"target": target, "mode": mode, "proof": proof})
            print("Windows storage API lifecycle", target, mode, "passed", flush=True)
    (folder / "results.json").write_text(json.dumps(results, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--runtime", type=Path, default=ROOT / "dist/windows-x86")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.build:
        build(args.runtime.resolve(), args.output.resolve())
    else:
        run(args.output.resolve())


if __name__ == "__main__":
    main()
