#!/usr/bin/env python3
"""Exercise the real AMD SMI dlopen wrapper without requiring an AMD GPU.

By default the fake DSO uses independently stored SDK declaration excerpts.
--sdk-root also compiles it against hash-pinned, unmodified upstream headers.
"""
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--cflags", default="-O1 -g -std=c17 -Wall -Wextra -Werror")
    parser.add_argument("--lua-prefix", type=Path, default=ROOT / ".tools/lua-5.5.1")
    parser.add_argument("--output", type=Path, default=ROOT / "build/native-amdsmi")
    parser.add_argument("--sdk-root", type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    compiler = shlex.split(args.cc)
    flags = shlex.split(args.cflags)
    lua = args.lua_prefix.resolve()
    harness = output / "amdsmi-fixture"
    subprocess.run(compiler + flags + ["-I" + str(lua / "include"),
                   str(ROOT / "tests/native/linux_amdsmi.c"), str(lua / "lib/liblua.a"),
                   "-ldl", "-lm", "-o", str(harness)], check=True)
    versions = json.loads((ROOT / "tests/fixtures/amdsmi/versions.json").read_text())
    for key, entry in versions.items():
        profile = str(entry.get("abi_profile", key))
        header_flags = []
        if args.sdk_root:
            header = (args.sdk_root / entry["tag"] / "amdsmi.h").resolve()
            if hashlib.sha256(header.read_bytes()).hexdigest() != entry["sha256"]:
                raise ValueError("SDK header hash mismatch: " + str(header))
            header_flags = ['-DWTOP_AMDSMI_SDK_HEADER="' + str(header) + '"']
        for variant in range(3):
            directory = output / (key + "-" + str(variant))
            directory.mkdir(exist_ok=True)
            definitions = ["-DWTOP_AMDSMI_PROFILE=" + profile,
                           "-DWTOP_AMDSMI_VERSION_RELEASE=" + str(entry["version"][-1])] + header_flags
            if variant == 1:
                definitions += ["-DWTOP_FAKE_NO_OPTIONAL"]
            if variant == 2:
                definitions += ["-DWTOP_FAKE_MISSING_REQUIRED"]
            subprocess.run(compiler + flags + ["-fPIC", "-shared"] + definitions
                           + [str(ROOT / "tests/native/amdsmi_fake.c"),
                              str(ROOT / "tests/native/amdsmi_layout.c"), "-o",
                              str(directory / "libamd_smi.so")], check=True)
            env = dict(os.environ)
            env["UBSAN_OPTIONS"] = env.get("UBSAN_OPTIONS", "") + ":halt_on_error=1"
            env["ASAN_OPTIONS"] = env.get("ASAN_OPTIONS", "") + ":detect_leaks=1:halt_on_error=1"
            env["LD_LIBRARY_PATH"] = str(directory) + os.pathsep + env.get("LD_LIBRARY_PATH", "")
            subprocess.run([str(harness), profile, str(variant)], env=env, check=True,
                           timeout=30)
    print("ok: 9 SDK versions across 8 AMD SMI ABI profiles, symbols and lifecycle")


if __name__ == "__main__":
    main()
