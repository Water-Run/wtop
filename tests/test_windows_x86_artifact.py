#!/usr/bin/env python3
"""The Windows loader gate must reject incompatible artifact shapes."""

from __future__ import annotations

import pathlib
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

# The other column shape objdump uses for a named import: an explicit ordinal
# column and the address ahead of the name.  Which release prints which is not
# the guard's question; "this row names an import" is.
assert Check.parse_objdump(
    report().replace("\tf388\t  275  DeleteCriticalSection",
                     "\t00001000 <none> 0001 DeleteCriticalSection"),
    "module.dll",
)["imports"]["kernel32.dll"] == {"DeleteCriticalSection", "GetTickCount"}

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
reports["libwinpthread-1.dll"]["imports"]["vcruntime140.dll"] = {"_beginthreadex"}
refused(lambda: Check.check_reports(reports, optional), "unbundled DLL")

with tempfile.TemporaryDirectory() as directory:
    (pathlib.Path(directory) / "wtop_windows.c").write_text("/* no lookups */")
    refused(lambda: Check.optional_api_names(pathlib.Path(directory)),
            "optional API scan lost")

print("ok: Windows x86 artifact gate rejects loader and import regressions")