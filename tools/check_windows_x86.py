#!/usr/bin/env python3
"""Check the loader-facing shape of a Windows x86 development bundle.

This is a static guard, not an XP runtime test. An import added by the app,
Lua, or a bundled runtime DLL can make the whole bundle fail to load before
wtop's own feature fallbacks run.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys


PE_FILES = (
    "lua.exe", "lua55.dll", "wtop_native.dll",
    "libgcc_s_dw2-1.dll", "libwinpthread-1.dll",
)
SYSTEM_DLLS = frozenset({
    "advapi32.dll", "iphlpapi.dll", "kernel32.dll", "msvcrt.dll",
    "psapi.dll", "setupapi.dll",
})
# These APIs are either newer than 32-bit XP or intentionally loaded only
# when an optional provider is present. A hard import bypasses that choice.
LATE_API_NAMES = frozenset({
    "GetTickCount64", "GetSystemTimes", "GetSystemFirmwareTable",
    "GetIfTable2", "FreeMibTable", "GetExtendedTcpTable",
    "GetExtendedUdpTable", "GetLogicalProcessorInformationEx",
    "GetActiveProcessorCount", "QueryFullProcessImageNameW",
    "CreateDXGIFactory1", "PdhAddEnglishCounterW", "PowerGetActiveScheme",
})
SOURCE_ANCHORS = frozenset({
    "GetTickCount64", "GetSystemTimes", "GetSystemFirmwareTable", "GetIfTable2",
})


def optional_api_names(native_dir: pathlib.Path) -> set[str]:
    source_files = sorted(native_dir.glob("wtop_windows*.c"))
    if not source_files:
        raise ValueError(f"no Windows native sources under {native_dir}")
    source = "\n".join(path.read_text(encoding="utf-8") for path in source_files)
    names = set(re.findall(
        r'GetProcAddress\s*\(\s*[^,]+,\s*"([A-Za-z][A-Za-z0-9_]*)"',
        source, re.S,
    ))
    names.update(re.findall(
        r'iphlpapi_export\s*\(\s*"([A-Za-z][A-Za-z0-9_]*)"', source,
    ))
    missing = SOURCE_ANCHORS - names
    if missing:
        raise ValueError("optional API scan lost: " + ", ".join(sorted(missing)))
    return names | LATE_API_NAMES


def parse_objdump(output: str, name: str) -> dict[str, object]:
    if not re.search(r"file format pei-i386\s*$", output, re.M):
        raise ValueError(f"{name}: not a PE32 i386 image")
    if not re.search(r"^Magic\s+[0-9a-fA-F]+\s+\(PE32\)\s*$", output, re.M):
        raise ValueError(f"{name}: PE optional header is not PE32")
    versions: dict[str, int] = {}
    for key in ("MajorOSystemVersion", "MinorOSystemVersion",
                "MajorSubsystemVersion", "MinorSubsystemVersion"):
        match = re.search(rf"^{key}\s+(\d+)\s*$", output, re.M)
        if not match:
            raise ValueError(f"{name}: {key} is missing")
        versions[key] = int(match.group(1))
    for kind in ("OSystem", "Subsystem"):
        version = versions[f"Major{kind}Version"], versions[f"Minor{kind}Version"]
        if version > (5, 1):
            raise ValueError(f"{name}: {kind} loader version {version} exceeds XP x86")

    imports: dict[str, set[str]] = {}
    current: str | None = None
    for line in output.splitlines():
        dll = re.match(r"^\s*DLL Name:\s*(\S+)\s*$", line)
        if dll:
            current = dll.group(1).lower()
            imports.setdefault(current, set())
            continue
        member = re.match(
            r"^\s*[0-9a-fA-F]+\s+<none>\s+[0-9a-fA-F]+\s+(\S+)\s*$", line,
        )
        if member and current:
            imports[current].add(member.group(1))
    if not imports:
        raise ValueError(f"{name}: no import table was parsed")
    return {"imports": imports, "versions": versions}


def check_reports(reports: dict[str, dict[str, object]],
                  optional_names: set[str]) -> tuple[int, int]:
    bundled = {name.lower() for name in reports}
    required = {name.lower() for name in PE_FILES}
    if bundled != required:
        raise ValueError("bundle PE files differ from the checked set: "
                         + ", ".join(sorted(bundled ^ required)))
    symbol_count = 0
    for name, report in reports.items():
        imports = report["imports"]
        if not isinstance(imports, dict):
            raise ValueError(f"{name}: invalid import report")
        for dll, symbols in imports.items():
            if dll not in SYSTEM_DLLS and dll not in bundled:
                raise ValueError(f"{name}: unbundled DLL import {dll}")
            if not isinstance(symbols, set) or not symbols:
                raise ValueError(f"{name}: {dll} has no named imports")
            for symbol in symbols:
                symbol_count += 1
                if symbol in optional_names:
                    raise ValueError(f"{name}: {dll}!{symbol} is hard-imported; "
                                     "keep the optional runtime lookup")
    return len(reports), symbol_count


def check_bundle(bundle: pathlib.Path, objdump: str,
                 native_dir: pathlib.Path) -> tuple[int, int]:
    if not (bundle / "src" / "wtop.lua").is_file():
        raise ValueError(f"{bundle}: Lua entry point is missing")
    for name in ("wtop.cmd", "wtop.sh"):
        if not (bundle / name).is_file():
            raise ValueError(f"{bundle}: {name} is missing")
    reports = {}
    for name in PE_FILES:
        path = bundle / name
        if not path.is_file():
            raise ValueError(f"{bundle}: {name} is missing")
        output = subprocess.run([objdump, "-p", str(path)], check=True,
                                capture_output=True, text=True,
                                env={**os.environ, "LC_ALL": "C"}).stdout
        reports[name] = parse_objdump(output, name)
    return check_reports(reports, optional_api_names(native_dir))


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=pathlib.Path,
                        default=root / "dist" / "windows-x86")
    parser.add_argument("--objdump", default="i686-w64-mingw32-objdump")
    args = parser.parse_args()
    try:
        images, symbols = check_bundle(args.bundle, args.objdump, root / "native")
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"wtop: Windows x86 static check failed: {exc}", file=sys.stderr)
        return 1
    print(f"wtop: Windows x86 static check: {images} PE32 i386 images, "
          f"{symbols} named imports; XP runtime remains untested")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
