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
    return (
        "module.dll: file format pei-i386\n"
        "Magic 010b (PE32)\n"
        "MajorOSystemVersion 4\nMinorOSystemVersion 0\n"
        "MajorSubsystemVersion 4\nMinorSubsystemVersion 0\n"
        "DLL Name: KERNEL32.dll\n"
        f" 00001000 <none> 0001 {symbol}\n"
        "DLL Name: lua55.dll\n"
        " 00001004 <none> 0002 lua_gettop\n"
    )


clean = Check.parse_objdump(report(), "module.dll")
assert clean["imports"]["kernel32.dll"] == {"GetTickCount"}
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
