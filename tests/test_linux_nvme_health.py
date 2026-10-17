#!/usr/bin/env python3
"""Exercise fixed native NVMe health reads without touching host devices."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--module", type=Path, required=True)
    parser.add_argument("--lua-prefix", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="wtop-nvme-health-") as temp:
        work = Path(temp)
        library = work / "nvme-health-io.so"
        subprocess.run([args.cc, "-std=c17", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-fPIC", "-shared", "-Inative", "tests/native/linux_nvme_health_io.c",
                        "-ldl", "-o", str(library)], cwd=ROOT, check=True)
        base = work / "block"
        disk = base / "nvme0n1"
        disk.mkdir(parents=True)
        (disk / "dev").write_text("259:0\n")
        (disk / "diskseq").write_text("7\n")
        device, control, entered = work / "device", work / "control", work / "entered"
        device.write_bytes(bytes(512))
        env = {**os.environ, "LUA_PATH": str(ROOT / "src/?.lua") + ";" + str(ROOT / "src/?/init.lua") + ";;",
               "LUA_CPATH": str(args.module.resolve().parent / "?.so") + ";;",
               "LD_PRELOAD": str(library), "WTOP_NVME_FIXTURE_DEVICE": str(device),
               "WTOP_NVME_FIXTURE_CONTROL": str(control), "WTOP_NVME_FIXTURE_ENTERED": str(entered)}
        subprocess.run([str(args.lua_prefix.resolve() / "bin/lua"),
                        str(ROOT / "tests/native/linux_nvme_worker.lua"), str(base), str(control), str(entered)],
                       cwd=ROOT, env=env, check=True, timeout=15)

if __name__ == "__main__":
    main()
