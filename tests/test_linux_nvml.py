#!/usr/bin/env python3
"""Exercise actual NVML dlopen calls, including legacy SDK symbol variants."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cc", default=os.environ.get("CC", "cc"))
    p.add_argument("--cflags", default="-O1 -g -std=c17 -Wall -Wextra -Werror")
    p.add_argument("--lua-prefix", type=Path, default=ROOT / ".tools/lua-5.5.1")
    p.add_argument("--output", type=Path, default=ROOT / "build/native-nvml")
    p.add_argument("--sdk-header", type=Path)
    args = p.parse_args()
    cc, flags = shlex.split(args.cc), shlex.split(args.cflags)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    lua = args.lua_prefix.resolve()
    header_flags = []
    if args.sdk_header:
        header = args.sdk_header.resolve()
        metadata = json.loads((ROOT / "tests/fixtures/nvml/sdk.json").read_text())
        if hashlib.sha256(header.read_bytes()).hexdigest() != metadata["sha256"]:
            raise ValueError("NVML SDK header digest mismatch")
        header_flags = ['-DWTOP_NVML_SDK_HEADER="' + str(header) + '"']
    harness = output / "nvml-fixture"
    subprocess.run(cc + flags + header_flags + ["-I" + str(lua / "include"),
                   str(ROOT / "tests/native/linux_nvml.c"), str(lua / "lib/liblua.a"),
                   "-lm", "-ldl", "-o", str(harness)], check=True)
    for variant in range(5):
        directory = output / str(variant)
        directory.mkdir(exist_ok=True)
        subprocess.run(cc + flags + header_flags + ["-fPIC", "-shared",
                       "-DWTOP_NVML_VARIANT=" + str(variant),
                       str(ROOT / "tests/native/nvml_fake.c"), "-o",
                       str(directory / "libnvidia-ml.so.1")], check=True)
        env = dict(os.environ)
        env.pop("WTOP_NVML_FIXTURE_MODE", None)
        env["LD_LIBRARY_PATH"] = str(directory) + os.pathsep + env.get("LD_LIBRARY_PATH", "")
        env["UBSAN_OPTIONS"] = env.get("UBSAN_OPTIONS", "") + ":halt_on_error=1"
        env["ASAN_OPTIONS"] = env.get("ASAN_OPTIONS", "") + ":detect_leaks=1:halt_on_error=1"
        subprocess.run([str(harness), str(variant)], env=env, check=True, timeout=30)
    print("ok: native NVML modern, v1, v2, missing symbols, and alias fallback")


if __name__ == "__main__":
    main()
