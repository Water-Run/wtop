#!/usr/bin/env python3
"""The Windows loader gate must reject incompatible artifact shapes."""

from __future__ import annotations

import pathlib
import struct
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_windows_x86 as Check  # noqa: E402


def refused(action, expected: str) -> None:
    try:
        action()
    except ValueError as exc:
        assert expected in str(exc), (expected, str(exc))
    else:
        raise AssertionError(f"an incompatible artifact passed: {expected}")


def report(symbol: str = "GetTickCount") -> str:
    """One real import section, captured from `i686-w64-mingw32-objdump -p`.

    The column layout this guard reads belongs to objdump, not to this file.
    The fixture used to be written by hand in a shape the parser remembered,
    and a parser that read none of a genuine table passed it: both halves were
    confidently wrong about the same format, which is why the gate reported
    every built bundle as having no named imports while reading none of them.
    Capturing a transcript keeps the fixture and the instrument describing the
    same object.  The relocation block before the header and the export table
    after it are part of the capture on purpose -- their rows have the same
    "address number name" shape as an import line and must not be read as one.
    """
    return (
        "PE File Base Relocations\n"
        "        vma    LDRVA  Type   Unknown\n"
        "       2a0  10820  Dir    12010  1218f  1\n"
        "\n"
        "lua.exe:     file format pei-i386\n"
        "\n"
        "Magic 010b (PE32)\n"
        "MajorOSystemVersion 4\n"
        "MinorOSystemVersion 0\n"
        "MajorSubsystemVersion 4\n"
        "MinorSubsystemVersion 4\n"
        "Time/Date 0x68e0f0f0\n"
        "\n"
        "The Import Tables (interpreted .idata section contents)\n"
        "\n"
        " vma:            Hint    Time      Forward  DLL       First\n"
        "                 Table   Stamp     Chain    Name      Thunk\n"
        " 0000f000\t0000f050 00000000 00000000 0000f9b8 0000f1ec\n"
        "\n"
        "\tDLL Name: kernel32.dll\n"
        "\tvma:  Hint/Ord Member-Name Bound-To\n"
        "\tf388\t  275  DeleteCriticalSection\n"
        f"\tf410\t  875  {symbol}\n"
        "\n"
        " 0000f014\t0000f09c 00000000 00000000 0000fa74 0000f238\n"
        "\n"
        "\tDLL Name: lua55.dll\n"
        "\tvma:  Hint/Ord Member-Name Bound-To\n"
        "\tf4ea\t   58  lua_gettop\n"
        "\n"
        "The Export Tables\n"
        "\n"
        " vma   ord   base  Name\n"
        "\t   0\t     0  [ordinal function #1]\n"
    )


clean = Check.parse_objdump(report(), "module.dll")
assert clean["imports"]["kernel32.dll"] == {"DeleteCriticalSection", "GetTickCount"}
assert clean["imports"]["lua55.dll"] == {"lua_gettop"}
assert not any(
    symbol.startswith("[") for symbols in clean["imports"].values()
    for symbol in symbols
), "an export row was read as an import"

# Binutils 2.46 prints a different header as well as different member rows.
# Keep both parts of its actual transcript together: changing just the rows
# leaves a parser that never enters the new table looking green.
ordinal_report = report().replace("Hint/Ord Member-Name", "Ordinal  Hint  Member-Name")
ordinal_report = ordinal_report.replace("\tf388\t  275  DeleteCriticalSection",
                                       "\t000101e4  <none>  0121  DeleteCriticalSection")
ordinal_report = ordinal_report.replace("\tf410\t  875  GetTickCount",
                                       "\t000101e8  <none>  0290  GetTickCount")
ordinal_report = ordinal_report.replace("\tf4ea\t   58  lua_gettop",
                                       "\t00010200  <none>  003a  lua_gettop")
assert Check.parse_objdump(ordinal_report, "module.dll")["imports"] == clean["imports"]
refused(lambda: Check.parse_objdump(
    ordinal_report.replace("Ordinal  Hint  Member-Name", "Unknown  Columns"),
    "module.dll"), "unrecognized objdump import header")

# A row the guard cannot read is a fact about the guard and not about the
# binary, so the message has to say so.  Reporting it as "no named imports"
# would assert a loader defect while having read nothing -- the same wrong
# answer the gate used to give for every real bundle.
refused(lambda: Check.parse_objdump(
    report().replace("\tf410\t  875  GetTickCount", "\tf410\t  ???"),
    "module.dll"), "unrecognized objdump import line")

# And an image whose import table the transcript never showed is missing one,
# which is a different defect from a table that arrived unreadable.
refused(lambda: Check.parse_objdump(
    report().replace("The Import Tables", "The Nothing Tables"),
    "module.dll"), "no import table was parsed")

refused(lambda: Check.parse_objdump(report().replace("pei-i386", "pei-x86-64"),
                                     "module.dll"), "not a PE32 i386")
refused(lambda: Check.parse_objdump(report().replace("(PE32)", "(PE32+)"),
                                     "module.dll"), "not PE32")
refused(lambda: Check.parse_objdump(report().replace("MajorSubsystemVersion 4",
                                                  "MajorSubsystemVersion 6"),
                                     "module.dll"), "exceeds XP x86")

reports = {name: {"imports": {"kernel32.dll": {"GetTickCount"}}}
           for name in Check.PE_FILES}
reports["wtop_native.dll"]["imports"]["lua55.dll"] = {"lua_gettop"}
optional = Check.optional_api_names(ROOT / "native")
assert {"GetTickCount64", "GetSystemTimes", "GetIfTable2"} <= optional
assert Check.check_reports(reports, optional)[0] == 5
static_reports = {name: reports[name] for name in Check.CORE_PE_FILES}
assert Check.check_reports(static_reports, optional)[0] == 3
missing_runtime = dict(static_reports)
missing_runtime.pop("lua55.dll")
refused(lambda: Check.check_reports(missing_runtime, optional), "missing core")
build_script = (ROOT / "tools" / "build_windows_x86.sh").read_text(encoding="utf-8")
assert ('python3 "$project_dir/tools/check_windows_x86.py" --bundle "$output_dir"'
        in build_script), "the gate must run on every completed Windows x86 build"
reports["wtop_native.dll"]["imports"]["kernel32.dll"].add("GetTickCount64")
refused(lambda: Check.check_reports(reports, optional), "hard-imported")
reports["wtop_native.dll"]["imports"]["kernel32.dll"].remove("GetTickCount64")
reports["wtop_native.dll"]["imports"]["kernel32.dll"].add("InitializeCriticalSectionEx")
refused(lambda: Check.check_reports(reports, optional), "hard-imported")
reports["wtop_native.dll"]["imports"]["kernel32.dll"].remove("InitializeCriticalSectionEx")
reports["libwinpthread-1.dll"]["imports"]["vcruntime140.dll"] = {"_beginthreadex"}
refused(lambda: Check.check_reports(reports, optional), "unbundled DLL")

with tempfile.TemporaryDirectory() as directory:
    (pathlib.Path(directory) / "wtop_windows.c").write_text("/* no lookups */")
    refused(lambda: Check.optional_api_names(pathlib.Path(directory)),
            "optional API scan lost")

# The onefile gate must see all its embedded PE headers, not just its launcher.
pe = bytearray(512)
pe[:2] = b"MZ"
struct.pack_into("<I", pe, 60, 64)
pe[64:68] = b"PE\0\0"
struct.pack_into("<HHIIIHH", pe, 68, 0x14C, 1, 0, 0, 0, 96, 0)
struct.pack_into("<H", pe, 88, 0x10B)
struct.pack_into("<I", pe, 148, 256)
struct.pack_into("<II", pe, 200, 256, 256)
assert len(Check.pe_images(bytes(pe) * 4)) == 4
refused(lambda: Check.pe_images(bytes(pe[:300])), "truncated embedded PE")
refused(lambda: Check.pe_images(b"prefix" + pe), "missing PE executable header")

# An unstripped MinGW executable has COFF symbols/string data after its last
# section. The complete embedded image must retain those bytes for objdump.
symbol_pe = bytearray(pe)
struct.pack_into("<II", symbol_pe, 76, 512, 1)
strings = b"a_long_symbol_name\0"
symbol_pe.extend(bytes(18) + struct.pack("<I", len(strings) + 4) + strings)
images = Check.pe_images(bytes(pe) + bytes(symbol_pe) + bytes(pe))
assert images[1] == (512, bytes(symbol_pe)) and len(images) == 3
refused(lambda: Check.pe_images(bytes(symbol_pe[:-1])), "truncated embedded PE")
bad_symbols = bytearray(symbol_pe)
struct.pack_into("<I", bad_symbols, 76, 0)
refused(lambda: Check.pe_images(bytes(bad_symbols)), "invalid embedded PE symbol table")
struct.pack_into("<I", symbol_pe, 530, 3)
refused(lambda: Check.pe_images(bytes(symbol_pe)), "invalid embedded PE string table")

certificate_pe = bytearray(pe)
struct.pack_into("<H", certificate_pe, 84, 136)
certificate_pe[224:264] = pe[184:224]
struct.pack_into("<I", certificate_pe, 180, 5)
struct.pack_into("<II", certificate_pe, 216, 512, 16)
certificate_pe.extend(bytes(16))
assert Check.pe_images(bytes(certificate_pe))[0][1] == bytes(certificate_pe)
refused(lambda: Check.pe_images(bytes(certificate_pe[:-1])), "truncated embedded PE")

print("ok: Windows x86 artifact gate rejects loader and import regressions")
