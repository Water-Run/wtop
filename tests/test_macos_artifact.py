#!/usr/bin/env python3
"""Reject deployment-floor regressions in macOS launchers and embedded images."""

from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import check_macos as Check


def image(minimum=(11, 0, 0), cpu=0x0100000C, legacy=False, dependency=None):
    value = (minimum[0] << 16) | (minimum[1] << 8) | minimum[2]
    commands = [struct.pack("<4I", 0x24, 16, value, value) if legacy
                else struct.pack("<6I", 0x32, 24, 1, value, value, 0)]
    if dependency:
        name = dependency.encode() + b"\0"
        length = (24 + len(name) + 7) // 8 * 8
        commands.append(struct.pack("<6I", 0xC, length, 24, 0, 0, 0)
                        + name.ljust(length - 24, b"\0"))
    payload = b"".join(commands)
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, len(commands), len(payload), 0, 0) + payload


def refused(data, message, embedded=False):
    try:
        Check.inspect(data, embedded)
    except ValueError as error:
        assert message in str(error), (message, str(error))
    else:
        raise AssertionError("incompatible Mach-O accepted: " + message)


arm = image(dependency="/usr/lib/libSystem.B.dylib")
assert Check.inspect(arm)[0]["minimum"] == (11, 0, 0)
assert Check.inspect(image((10, 13, 0), 0x01000007, legacy=True))[0]["architecture"] == "x86_64"
refused(image((26, 0, 0)), "exceeds target")
refused(image((10, 14, 0), 0x01000007, legacy=True), "exceeds target")
refused(image(dependency="/opt/homebrew/lib/liblua.dylib"), "non-system dylib")
refused(arm[:40], "load command bounds")
refused(image((0, 0, 0)), "deployment information")
refused(arm, "missing its embedded", embedded=True)
assert len(Check.inspect(arm + b"payload" + arm + arm, embedded=True)) == 3
refused(arm + arm + image((26, 0, 0)), "exceeds target", embedded=True)
refused(arm + arm + image((10, 13, 0), 0x01000007), "mixed Mach-O", embedded=True)
refused(arm + arm + image(dependency="/tmp/build/liblua.dylib"), "non-system dylib", embedded=True)
print("ok: macOS gate checks deployment floors and dependencies in every embedded image")
