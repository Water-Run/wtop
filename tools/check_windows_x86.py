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
import struct
import subprocess
import sys
import tempfile


PE_FILES = (
    "lua.exe", "lua55.dll", "wtop_native.dll",
    "libgcc_s_dw2-1.dll", "libwinpthread-1.dll",
)
CORE_PE_FILES = ("lua.exe", "lua55.dll", "wtop_native.dll")
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
    "InitializeCriticalSectionEx",
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


# objdump prints one DLL's imports as a "DLL Name:" line, a column header
# naming the member column, and then a line per imported symbol.  Reading only
# the lines under that header is what keeps an export table, a base relocation
# or an address-table entry -- which have the same "address number name" shape
# -- from being reported as imports the loader never resolves.
IMPORT_SECTION = re.compile(r"^The Import Tables\b")
# Each table inside the import section starts with its own column line, and two
# of them share a prefix: one heads the per-DLL directory rows, the other the
# per-symbol member rows.  Only the second is followed by imports, so accepting
# the first as the second would read a directory entry -- "<vma> <hint table>
# <time stamp> <forwarder chain> <name rva> <first thunk>" -- as a symbol.
COLUMN_HEADER = re.compile(r"^\s+vma:\s")
MEMBER_HEADER = re.compile(r"^\s+vma:\s+(?:Hint/Ord|Ordinal\s+Hint)\s+Member-Name\b")
# That column header is printed once for the whole section, while its directory
# rows sit between the DLL blocks, so a directory row cannot be recognised by
# the header above it.  It can be recognised by itself: six address-sized
# fields and no name column, where a member row carries three.
IMPORT_DIRECTORY_ROW = re.compile(
    r"^\s*[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+[0-9a-fA-F]+\s+"
    r"[0-9a-fA-F]+\s+[0-9a-fA-F]+\s*$",
)
# A member is "<vma> <hint> <name>".  Releases that carry an ordinal column
# print an explicit "<none>" and the address ahead of the name instead; both
# shapes state the same fact, so both are read, and a line under the header
# that matches neither is reported rather than dropped.  Dropping it would turn
# this guard into a hole: an unread table yields empty symbol sets, and an empty
# symbol set is already the verdict for "this DLL imports nothing", so the
# parser would report a loader-facing defect that the binary does not have
# while reading none of the defects it is there to find.
IMPORT_MEMBER = re.compile(
    r"^\s*[0-9a-fA-F]+\s+(?:[0-9a-fA-F]+|<none>)\s+(?:[0-9a-fA-F]+\s+)?(\S+)\s*$",
)


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
    under_members = False
    unread: list[str] = []
    in_imports = False
    for line in output.splitlines():
        if IMPORT_SECTION.match(line):
            in_imports = True
            continue
        if in_imports and line and not line[0].isspace():
            in_imports = False
        if not in_imports:
            continue
        dll = re.match(r"^\s*DLL Name:\s*(\S+)\s*$", line)
        if dll:
            current = dll.group(1).lower()
            imports.setdefault(current, set())
            under_members = False
            continue
        if IMPORT_DIRECTORY_ROW.match(line):
            continue
        if COLUMN_HEADER.match(line):
            under_members = bool(MEMBER_HEADER.match(line))
            if current and not under_members:
                raise ValueError(f"{name}: unrecognized objdump import header {line.strip()!r}")
            continue
        if not (current and under_members) or not line.strip():
            continue
        member = IMPORT_MEMBER.match(line)
        if member:
            imports[current].add(member.group(1))
        else:
            unread.append(line.strip())
    if unread:
        raise ValueError(f"{name}: unrecognized objdump import line {unread[0]!r}")
    if not imports:
        raise ValueError(f"{name}: no import table was parsed")
    return {"imports": imports, "versions": versions}


def check_reports(reports: dict[str, dict[str, object]],
                  optional_names: set[str],
                  required_files=CORE_PE_FILES) -> tuple[int, int]:
    bundled = {name.lower() for name in reports}
    required = {name.lower() for name in required_files}
    if not required.issubset(bundled) or len(bundled) != len(reports):
        raise ValueError("bundle is missing core PE files or has case collisions: "
                         + ", ".join(sorted(required - bundled)))
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
    for name in CORE_PE_FILES:
        if not (bundle / name).is_file():
            raise ValueError(f"{bundle}: {name} is missing")
    for path in sorted(bundle.iterdir()):
        if path.suffix.lower() not in (".exe", ".dll"):
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"{path}: PE image is not a regular file")
        name = path.name
        output = subprocess.run([objdump, "-p", str(path)], check=True,
                                capture_output=True, text=True,
                                env={**os.environ, "LC_ALL": "C"}).stdout
        reports[name] = parse_objdump(output, name)
    return check_reports(reports, optional_api_names(native_dir))


def pe_images(data: bytes) -> list[tuple[int, bytes]]:
    """Find complete PE images, including the raw payload in a onefile program."""
    images, offset = [], data.find(b"MZ")
    while offset >= 0:
        if offset + 64 <= len(data):
            pe = offset + struct.unpack_from("<I", data, offset + 60)[0]
            if pe >= offset + 64 and pe + 24 <= len(data) and data[pe:pe + 4] == b"PE\0\0":
                _, sections, _, _, _, optional_size, _ = struct.unpack_from("<HHIIIHH", data, pe + 4)
                table = pe + 24 + optional_size
                if not 0 < sections <= 96 or optional_size < 64 or table + sections * 40 > len(data):
                    raise ValueError("invalid embedded PE section table")
                size = struct.unpack_from("<I", data, pe + 24 + 60)[0]
                for index in range(sections):
                    raw_size, raw_offset = struct.unpack_from("<II", data, table + index * 40 + 16)
                    size = max(size, raw_offset + raw_size)
                if size < table + sections * 40 - offset or offset + size > len(data):
                    raise ValueError("truncated embedded PE image")
                images.append((offset, data[offset:offset + size]))
        offset = data.find(b"MZ", offset + 2)
    if not images or images[0][0] != 0:
        raise ValueError("missing PE executable header")
    return images


def check_packaged(bundle: pathlib.Path, objdump: str,
                   native_dir: pathlib.Path, kind: str = "both") -> tuple[int, int]:
    required = ("wtop.exe", "lua55.dll", "wtop_native.dll")
    optional = optional_api_names(native_dir)

    def report(path, name):
        output = subprocess.run([objdump, "-p", str(path)], check=True,
                                capture_output=True, text=True,
                                env={**os.environ, "LC_ALL": "C"}).stdout
        result = parse_objdump(output, name)
        exported = re.search(r"^Name\s+[0-9a-fA-F]+\s+(\S+\.dll)\s*$", output, re.M | re.I)
        return result, exported[1] if exported else None

    direct_count, direct_symbols = 0, 0
    if kind in ("dir", "both"):
        reports = {}
        for path in sorted((bundle / "wtop").rglob("*")):
            if path.suffix.lower() not in (".exe", ".dll"):
                continue
            if path.is_symlink() or not path.is_file() or path.name.lower() in reports:
                raise ValueError("invalid or duplicate packaged PE: " + str(path))
            reports[path.name.lower()] = report(path, path.name)[0]
        direct_count, direct_symbols = check_reports(reports, optional, required)
        if kind == "dir":
            return direct_count, direct_symbols
    onefile = bundle / "wtop-onefile.exe"
    if onefile.is_symlink() or not onefile.is_file():
        raise ValueError("missing regular onefile executable")
    images = pe_images(onefile.read_bytes())
    if len(images) < 4:
        raise ValueError("onefile is missing its embedded program or DLLs")
    reports = {}
    with tempfile.TemporaryDirectory(prefix="wtop-pe-") as directory:
        for index, (offset, data) in enumerate(images):
            path = pathlib.Path(directory) / f"image-{index}.exe"
            path.write_bytes(data)
            result, exported = report(path, f"onefile PE at +{offset}")
            name = exported.lower() if exported else f"image-{index}.exe"
            if name in reports:
                raise ValueError("duplicate embedded DLL: " + name)
            reports[name] = result
    embedded_count, embedded_symbols = check_reports(reports, optional,
                                                      ("lua55.dll", "wtop_native.dll"))
    return direct_count + embedded_count, direct_symbols + embedded_symbols


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=pathlib.Path,
                        default=root / "dist" / "windows-x86")
    parser.add_argument("--objdump", default="i686-w64-mingw32-objdump")
    parser.add_argument("--packaged", action="store_true",
                        help="check onedir and onefile under a windows-bundle directory")
    parser.add_argument("--kind", choices=("dir", "file", "both"), default="both")
    args = parser.parse_args()
    try:
        if args.packaged:
            images, symbols = check_packaged(args.bundle, args.objdump, root / "native", args.kind)
        else:
            images, symbols = check_bundle(args.bundle, args.objdump, root / "native")
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"wtop: Windows x86 static check failed: {exc}", file=sys.stderr)
        return 1
    print(f"wtop: Windows x86 static check: {images} PE32 i386 images, "
          f"{symbols} named imports; XP runtime remains untested")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
