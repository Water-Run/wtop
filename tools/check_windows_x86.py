#!/usr/bin/env python3
"""Check the loader-facing shape of a Windows x86 development bundle.

This is a static guard, not an XP runtime test. An import added by the app,
Lua, or a bundled runtime DLL can make the whole bundle fail to load before
wtop's own feature fallbacks run.
"""

from __future__ import annotations

import argparse
import hashlib
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
    source_files += sorted(native_dir.glob("wtop_cpuid*.c"))
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


def parse_objdump(output: str, name: str, architecture: str = "x86") -> dict[str, object]:
    image_format, magic, maximum = ("pei-i386", "PE32", (5, 1))
    if architecture == "x64":
        image_format, magic, maximum = "pei-x86-64", "PE32+", (5, 2)
    elif architecture != "x86":
        raise ValueError("unknown PE architecture")
    if not re.search(rf"file format {re.escape(image_format)}\s*$", output, re.M):
        raise ValueError(f"{name}: not a {magic} {'i386' if architecture == 'x86' else 'x64'} image")
    if not re.search(rf"^Magic\s+[0-9a-fA-F]+\s+\({re.escape(magic)}\)\s*$", output, re.M):
        raise ValueError(f"{name}: PE optional header is not {magic}")
    versions: dict[str, int] = {}
    for key in ("MajorOSystemVersion", "MinorOSystemVersion",
                "MajorSubsystemVersion", "MinorSubsystemVersion"):
        match = re.search(rf"^{key}\s+(\d+)\s*$", output, re.M)
        if not match:
            raise ValueError(f"{name}: {key} is missing")
        versions[key] = int(match.group(1))
    for kind in ("OSystem", "Subsystem"):
        version = versions[f"Major{kind}Version"], versions[f"Minor{kind}Version"]
        if version > maximum:
            raise ValueError(f"{name}: {kind} loader version {version} exceeds XP {architecture}")

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


def worker_images(data: bytes, images: list[tuple[int, bytes]]) -> dict[int, str]:
    """Only the two self-contained workers declared inside the module may
    have a different architecture. Primary programs/DLLs stay PE32/XP x86.
    Digests and complete lengths bind each role to one embedded PE image.
    This is an artifact consistency check, not a substitute for signatures.
    """
    marker = b"WTOP_CPUID_WORKERS_V1\n"
    if marker not in data:
        return {}
    matches = list(re.finditer(
        rb"WTOP_CPUID_WORKERS_V1\nx86:([1-9][0-9]*):([0-9a-f]{64})\n"
        rb"x64:([1-9][0-9]*):([0-9a-f]{64})\nEND_WTOP_CPUID_WORKERS\n", data))
    if len(matches) != 1 or data.count(marker) != 1:
        raise ValueError("invalid CPUID worker manifest")
    manifest = matches[0]
    expected = {manifest[2].decode(): (int(manifest[1]), "x86"),
                manifest[4].decode(): (int(manifest[3]), "x64")}
    if len(expected) != 2 or any(not 0 < length <= 512 * 1024 for length, _ in expected.values()):
        raise ValueError("invalid CPUID worker lengths or identities")
    found, consumed = {}, set()
    for offset, image in images:
        digest = hashlib.sha256(image).hexdigest()
        if digest in consumed:
            raise ValueError("duplicate CPUID worker image")
        if digest in expected:
            length, architecture = expected.pop(digest)
            if offset == 0 or len(image) != length:
                raise ValueError("CPUID worker must be a complete embedded image")
            found[offset] = architecture
            consumed.add(digest)
    if expected:
        raise ValueError("CPUID worker is missing, duplicated or changed")
    return found


def parse_worker64(data: bytes, name: str) -> dict[str, object]:
    """Read the optional x64 worker without requiring an x64 build-host
    toolchain. The native Windows packager itself uses only an x86 compiler.
    Imports are bounded RVAs into raw sections, not strings scanned in code.
    """
    def read(fmt, offset):
        if offset < 0 or offset + struct.calcsize(fmt) > len(data):
            raise ValueError(f"{name}: truncated x64 PE")
        return struct.unpack_from(fmt, data, offset)

    pe, = read("<I", 60)
    if data[:2] != b"MZ" or data[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"{name}: missing x64 PE header")
    machine, sections, _, _, _, optional_size, flags = read("<HHIIIHH", pe + 4)
    optional, table = pe + 24, pe + 24 + optional_size
    if machine != 0x8664 or read("<H", optional)[0] != 0x20b or optional_size < 128:
        raise ValueError(f"{name}: not a PE32+ x64 worker")
    if not 0 < sections <= 96 or flags & 0x2000 or read("<H", optional + 68)[0] != 3 or not read("<I", optional + 16)[0]:
        raise ValueError(f"{name}: invalid x64 worker image type")
    versions = {}
    for kind, offset in (("OSystem", 40), ("Subsystem", 48)):
        major, minor = read("<HH", optional + offset)
        if (major, minor) > (5, 2):
            raise ValueError(f"{name}: {kind} loader version exceeds XP x64")
        versions["Major" + kind + "Version"], versions["Minor" + kind + "Version"] = major, minor
    headers, = read("<I", optional + 60)
    mappings = []
    for index in range(sections):
        virtual_size, rva, size, offset = read("<IIII", table + index * 40 + 8)
        if offset + size > len(data):
            raise ValueError(f"{name}: truncated x64 section")
        mappings.append((rva, max(virtual_size, size), size, offset))

    def raw(rva, size):
        candidates = [offset + rva - start for start, virtual, length, offset in mappings
                      if start <= rva < start + virtual and rva - start + size <= length]
        if not candidates and 0 <= rva and rva + size <= min(headers, len(data)):
            return rva
        if len(candidates) != 1:
            raise ValueError(f"{name}: invalid or ambiguous x64 import RVA")
        return candidates[0]

    def string(rva):
        output = bytearray()
        for index in range(1024):
            value = data[raw(rva + index, 1)]
            if not value:
                if output:
                    return output.decode("ascii")
                break
            if not 32 <= value < 127:
                break
            output.append(value)
        raise ValueError(f"{name}: invalid x64 import name")

    directories, = read("<I", optional + 108)
    rva, size = read("<II", optional + 120)
    if directories < 2 or not rva or not 20 <= size <= 65536:
        raise ValueError(f"{name}: missing x64 import directory")
    imports, terminated = {}, False
    for index in range(min(size // 20, 128)):
        lookup, stamp, chain, dll, first = read("<IIIII", raw(rva + index * 20, 20))
        if not (lookup or stamp or chain or dll or first):
            terminated = True
            break
        library = string(dll).lower()
        if library in imports:
            raise ValueError(f"{name}: duplicate x64 import library")
        symbols, end = set(), False
        for entry in range(8192):
            value, = read("<Q", raw((lookup or first) + entry * 8, 8))
            if not value:
                end = True
                break
            if value >= 0x80000000:
                raise ValueError(f"{name}: unsupported ordinal or oversized x64 import")
            symbols.add(string(value + 2))
        if not end or not symbols:
            raise ValueError(f"{name}: invalid x64 import thunk table")
        imports[library] = symbols
    if not terminated or not imports:
        raise ValueError(f"{name}: unterminated x64 import directory")
    return {"imports": imports, "versions": versions}


def inspect_images(data: bytes, objdump: str, name: str):
    images = pe_images(data)
    workers = worker_images(data, images)
    reports = []
    with tempfile.TemporaryDirectory(prefix="wtop-pe-") as directory:
        for index, (offset, image) in enumerate(images):
            path = pathlib.Path(directory) / f"image-{index}.exe"
            path.write_bytes(image)
            architecture = workers.get(offset, "x86")
            if architecture == "x64":
                result = parse_worker64(image, name)
                check_reports({"worker.exe": result}, set(), ())
                reports.append((offset, result, "cpuid-x64.exe"))
                continue
            output = subprocess.run([objdump, "-p", str(path)], check=True,
                                    capture_output=True, text=True,
                                    env={**os.environ, "LC_ALL": "C"}).stdout
            result = parse_objdump(output, f"{name} PE at +{offset}", architecture)
            if offset in workers:
                check_reports({"worker.exe": result}, set(), ())
            exported = re.search(r"^Name\s+[0-9a-fA-F]+\s+(\S+\.dll)\s*$", output, re.M | re.I)
            role = "cpuid-" + architecture + ".exe" if offset in workers else None
            reports.append((offset, result, role or (exported[1].lower() if exported else None)))
    return reports


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
        for offset, result, role in inspect_images(path.read_bytes(), objdump, name):
            key = name if offset == 0 else role
            if not key or key in reports:
                raise ValueError("unexpected or duplicate embedded PE")
            reports[key] = result
    return check_reports(reports, optional_api_names(native_dir))


def pe_images(data: bytes) -> list[tuple[int, bytes]]:
    """Find complete PE images, including the raw payload in a onefile program."""
    images, offset = [], data.find(b"MZ")
    while offset >= 0:
        if offset + 64 <= len(data):
            pe = offset + struct.unpack_from("<I", data, offset + 60)[0]
            if pe >= offset + 64 and pe + 24 <= len(data) and data[pe:pe + 4] == b"PE\0\0":
                _, sections, _, symbols, symbol_count, optional_size, _ = struct.unpack_from("<HHIIIHH", data, pe + 4)
                table = pe + 24 + optional_size
                if not 0 < sections <= 96 or optional_size < 64 or table + sections * 40 > len(data):
                    raise ValueError("invalid embedded PE section table")
                size = struct.unpack_from("<I", data, pe + 24 + 60)[0]
                for index in range(sections):
                    raw_size, raw_offset = struct.unpack_from("<II", data, table + index * 40 + 16)
                    size = max(size, raw_offset + raw_size)
                # MinGW leaves COFF symbols and their string table after the
                # sections. Truncating there makes objdump reject a valid PE,
                # including the outer onefile program itself.
                if symbols:
                    strings = symbols + symbol_count * 18
                    if offset + strings + 4 > len(data):
                        raise ValueError("truncated embedded PE symbol table")
                    string_size = struct.unpack_from("<I", data, offset + strings)[0]
                    if string_size < 4:
                        raise ValueError("invalid embedded PE string table")
                    size = max(size, strings + string_size)
                elif symbol_count:
                    raise ValueError("invalid embedded PE symbol table")
                # The certificate table also uses a file offset, not an RVA.
                magic = struct.unpack_from("<H", data, pe + 24)[0]
                directories = 96 if magic == 0x10B else 112 if magic == 0x20B else 0
                if directories and optional_size >= directories + 40:
                    directory_count = struct.unpack_from("<I", data, pe + 24 + directories - 4)[0]
                    if directory_count > 4:
                        certificate, certificate_size = struct.unpack_from(
                            "<II", data, pe + 24 + directories + 32)
                        if certificate_size:
                            if not certificate:
                                raise ValueError("invalid embedded PE certificate table")
                            size = max(size, certificate + certificate_size)
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

    direct_count, direct_symbols = 0, 0
    if kind in ("dir", "both"):
        reports = {}
        for path in sorted((bundle / "wtop").rglob("*")):
            if path.suffix.lower() not in (".exe", ".dll"):
                continue
            if path.is_symlink() or not path.is_file() or path.name.lower() in reports:
                raise ValueError("invalid or duplicate packaged PE: " + str(path))
            for offset, result, role in inspect_images(path.read_bytes(), objdump, path.name):
                key = path.name.lower() if offset == 0 else role
                if not key or key in reports:
                    raise ValueError("unexpected or duplicate packaged PE")
                reports[key] = result
        direct_count, direct_symbols = check_reports(reports, optional, required)
        if kind == "dir":
            return direct_count, direct_symbols
    onefile = bundle / "wtop-onefile.exe"
    if onefile.is_symlink() or not onefile.is_file():
        raise ValueError("missing regular onefile executable")
    images = inspect_images(onefile.read_bytes(), objdump, "onefile")
    if len(images) < 4:
        raise ValueError("onefile is missing its embedded program or DLLs")
    reports = {}
    for index, (offset, result, role) in enumerate(images):
        name = role or f"image-{index}.exe"
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
    print(f"wtop: Windows x86 static check: {images} PE images (primary x86, declared workers checked), "
          f"{symbols} named imports; XP runtime remains untested")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
