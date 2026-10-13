#!/usr/bin/env python3
"""Check macOS deployment floors and dependencies, including onefile payloads."""

from __future__ import annotations

import argparse
from pathlib import Path
import struct


MAGIC = b"\xcf\xfa\xed\xfe"
TARGETS = {0x01000007: ("x86_64", (10, 13, 0)), 0x0100000C: ("arm64", (11, 0, 0))}
LOAD_DYLIB = {0xC, 0x80000018, 0x8000001F, 0x80000023}


def version(value: int) -> tuple[int, int, int]:
    return value >> 16, (value >> 8) & 255, value & 255


def inspect_image(data: bytes, offset: int) -> dict:
    if data[offset:offset + 4] != MAGIC or offset + 32 > len(data):
        raise ValueError("missing 64-bit Mach-O header")
    _, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data, offset)
    if cpu not in TARGETS or kind not in (2, 6, 8):
        raise ValueError("unsupported Mach-O architecture or image type")
    end = offset + 32 + size
    if not 0 < count <= 4096 or end > len(data):
        raise ValueError("invalid Mach-O load command bounds")
    position, minimum, dependencies = offset + 32, None, []
    for _ in range(count):
        if position + 8 > end:
            raise ValueError("truncated Mach-O load command")
        command, length = struct.unpack_from("<2I", data, position)
        if length < 8 or length % 4 or position + length > end:
            raise ValueError("invalid Mach-O load command size")
        declared = None
        if command == 0x32:  # LC_BUILD_VERSION
            if length < 24 or struct.unpack_from("<I", data, position + 8)[0] != 1:
                raise ValueError("invalid macOS build version")
            declared = version(struct.unpack_from("<I", data, position + 12)[0])
        elif command == 0x24:  # LC_VERSION_MIN_MACOSX
            if length < 16:
                raise ValueError("truncated macOS minimum version")
            declared = version(struct.unpack_from("<I", data, position + 8)[0])
        elif command in LOAD_DYLIB:
            if length < 24:
                raise ValueError("truncated dylib dependency")
            start = struct.unpack_from("<I", data, position + 8)[0]
            if not 24 <= start < length:
                raise ValueError("invalid dylib name offset")
            raw = data[position + start:position + length]
            if b"\0" not in raw:
                raise ValueError("unterminated dylib dependency")
            dependencies.append(raw.split(b"\0", 1)[0].decode("utf-8"))
        if declared is not None:
            if minimum is not None:
                raise ValueError("duplicate macOS minimum version")
            minimum = declared
        position += length
    if position != end or minimum is None or minimum == (0, 0, 0):
        raise ValueError("incomplete Mach-O deployment information")
    architecture, floor = TARGETS[cpu]
    if minimum > floor:
        raise ValueError(f"{architecture} minimum {minimum} exceeds target {floor}")
    for dependency in dependencies:
        if not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise ValueError("non-system dylib dependency: " + dependency)
    return {"offset": offset, "architecture": architecture, "minimum": minimum,
            "dependencies": dependencies}


def inspect(data: bytes, embedded: bool = False) -> list[dict]:
    images = [inspect_image(data, 0)]
    if embedded:
        offset = data.find(MAGIC, 32)
        while offset >= 0:
            # Ignore a magic constant in code; actual payload headers also
            # identify their image type and a bounded load-command region.
            if offset + 32 <= len(data):
                header = struct.unpack_from("<8I", data, offset)
                if header[3] in (2, 6, 8) and 0 < header[4] <= 4096:
                    images.append(inspect_image(data, offset))
            offset = data.find(MAGIC, offset + 4)
        if len(images) < 3:
            raise ValueError("onefile is missing its embedded program or native module")
    if len({image["architecture"] for image in images}) != 1:
        raise ValueError("mixed Mach-O architectures")
    return images


def check_bundle(bundle: Path) -> list[tuple[str, list[dict]]]:
    required = ("wtop/wtop", "wtop/.luai/native/wtop_native.so", "wtop-onefile")
    results = []
    for name in required:
        path = bundle / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("missing regular Mach-O image: " + name)
        try:
            images = inspect(path.read_bytes(), embedded=name == "wtop-onefile")
        except ValueError as error:
            raise ValueError(name + ": " + str(error)) from error
        results.append((name, images))
    if len({image["architecture"] for _, images in results for image in images}) != 1:
        raise ValueError("bundle contains mixed Mach-O architectures")
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path("dist/macos-bundle"))
    args = parser.parse_args()
    try:
        for name, images in check_bundle(args.bundle):
            minimum = max(image["minimum"] for image in images)
            print(f"{name}: {len(images)} Mach-O images, {images[0]['architecture']}, "
                  + "minimum macOS " + ".".join(map(str, minimum)))
    except (OSError, ValueError) as error:
        parser.exit(1, "wtop: macOS compatibility check failed: " + str(error) + "\n")
    print("wtop: macOS static check passed; older-system runtime remains untested")


if __name__ == "__main__":
    main()
