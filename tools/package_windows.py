#!/usr/bin/env python3
"""Build native Windows x86 luainstaller bundles from the development runtime."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

from check_windows_x86 import check_packaged


INSTALLER = "luainstaller-1.5.0-1.src.rock"
INSTALLER_SHA256 = "5d57d07e539107cc13e171e2b0a5919be692898c2627acfda4bcd12694055545"
INSTALLER_URL = "https://github.com/Water-Run/luainstaller/releases/download/v1.5.0/" + INSTALLER
ONEFILE_SOURCE_SHA256 = "67edbb961affcc496ad99a1bcdd342f07e0a2c488bed6de3442b8ac23e989a68"


def installer_archive(root: Path) -> Path:
    archive = root / ".tools" / "downloads" / INSTALLER
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        temporary = archive.with_suffix(".part")
        try:
            with urllib.request.urlopen(INSTALLER_URL, timeout=30) as response:
                with temporary.open("wb") as output:
                    shutil.copyfileobj(response, output)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != INSTALLER_SHA256:
                raise ValueError("luainstaller source checksum mismatch")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != INSTALLER_SHA256:
        raise ValueError("luainstaller source checksum mismatch")
    return archive


def copy_vendor_notices(root: Path, output_root: Path) -> None:
    for name in ("NVML-NVIDIA.txt", "Level-Zero-MIT.txt", "AMD-ADL-MIT.txt", "DRM-EDID-MIT.txt"):
        notice = root / "native" / "licenses" / name
        shutil.copy2(notice, output_root / name)
        directory = output_root / "wtop"
        if directory.is_dir():
            licenses = directory / ".luai" / "licenses"
            licenses.mkdir(parents=True, exist_ok=True)
            shutil.copy2(notice, licenses / name)


def prepare_onefile_payload(root: Path, source: Path) -> None:
    """Keep the pinned extractor, using compact C literals for its payload."""
    module = source / "luainstaller" / "src" / "onefile.lua"
    original = module.read_bytes()
    if hashlib.sha256(original).hexdigest() != ONEFILE_SOURCE_SHA256:
        raise ValueError("unexpected luainstaller onefile source")
    text = original.decode("utf-8")
    start = text.index("local function emitFileArrays(files)\n")
    end = text.index("\nlocal EXTRACTOR_TEMPLATE", start)
    emitter = (root / "tools" / "windows_payload.lua").read_text(encoding="utf-8")
    replacement = "local emitFileArrays = (function()\n" + emitter + "\nend)()\n"
    module.write_text(text[:start] + replacement + text[end:], encoding="utf-8", newline="\n")


def build(root: Path, kind: str, compiler: str | None = None, verbose: bool = False) -> Path:
    if os.name != "nt":
        raise ValueError("Windows packaging must run on Windows")
    runtime = root / "dist" / "windows-x86"
    source_root = runtime / "src"
    lua = runtime / "lua.exe"
    for name in ("lua.exe", "lua55.dll", "liblua55.dll.a", "wtop_native.dll"):
        if not (runtime / name).is_file():
            raise ValueError("build and copy dist/windows-x86 first: missing " + name)
    if not (source_root / "wtop.lua").is_file():
        raise ValueError("development runtime is missing its matching Lua sources")
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
    compiler = compiler or os.environ.get("LUAI_CC") or shutil.which("i686-w64-mingw32-gcc") or shutil.which("gcc")
    if not compiler:
        raise ValueError("an x86 MinGW compiler targeting MSVCRT is required (--compiler or LUAI_CC)")
    compiler = Path(shutil.which(compiler) or compiler).resolve()
    environment["LUAI_CC"] = str(compiler)
    environment["PATH"] = str(compiler.parent) + os.pathsep + environment.get("PATH", "")
    machine = subprocess.check_output([str(compiler), "-dumpmachine"], env=environment,
                                      text=True, timeout=30).strip()
    if machine != "i686-w64-mingw32":
        raise ValueError("the compiler must target i686-w64-mingw32, got " + machine)
    objdump = compiler.with_name(compiler.name.replace("gcc", "objdump"))
    if objdump == compiler or not objdump.is_file():
        raise ValueError("the compiler's matching objdump is required")
    subprocess.run([str(lua), "-e", "assert(_VERSION == 'Lua 5.5' and string.packsize('T') == 4)"],
                   env=environment, check=True, timeout=30)
    # A 64-bit Python inherits AMD64 even when it starts a 32-bit Lua. The
    # packager selects its compiler using the child environment, so describe
    # the verified runtime rather than Python's architecture.
    environment["PROCESSOR_ARCHITECTURE"] = "x86"
    archive = installer_archive(root)
    output_root = root / "dist" / "windows-bundle"
    output_root.mkdir(parents=True, exist_ok=True)
    output = output_root / ("wtop" if kind == "dir" else "wtop-onefile.exe")
    # Use freshly extracted, digest-verified source on every build. A stale or
    # locally edited installer cache must not change the pinned packager.
    with tempfile.TemporaryDirectory(prefix="wtop-packager-") as directory:
        source = Path(directory)
        with zipfile.ZipFile(archive) as rock:
            rock.extractall(source)
        if kind == "file":
            prepare_onefile_payload(root, source)
        if kind == "dir" and output.exists():
            # The project licence is added after luainstaller's ownership list,
            # so a repeat build must start with an empty output directory.
            shutil.rmtree(output)
        environment["LUA_PATH"] = str(source_root / "?.lua") + ";" + str(source_root / "?" / "init.lua") + ";;"
        environment["LUA_CPATH"] = str(runtime / "?.dll") + ";;"
        command = [str(lua), str(source / "luainstaller" / "bin" / "luai.lua"),
                   "-b", "--" + kind, str(source_root / "wtop.lua"),
                   "-o", str(output), "--lua", str(lua), "--lua-prefix", str(runtime),
                   "--target-os", "windows", "--max-deps", "300"]
        if verbose:
            command.append("--verbose")
        for locale in sorted((source_root / "wtop" / "generated" / "locales").glob("*.lua")):
            command.extend(["--include", str(locale)])
        subprocess.run(command + ["--", "--version"], env=environment, cwd=root,
                       check=True, timeout=900)
    shutil.copy2(root / "LICENSE", output_root / "LICENSE")
    if kind == "dir":
        shutil.copy2(root / "LICENSE", output / "LICENSE")
    copy_vendor_notices(root, output_root)
    images, symbols = check_packaged(output_root, str(objdump), root / "native", kind)
    print(f"wtop: checked {images} PE images (primary x86, declared workers checked) and {symbols} named imports")
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("dir", "file"))
    parser.add_argument("--compiler", help="native x86 MinGW compiler targeting MSVCRT (or set LUAI_CC)")
    parser.add_argument("--verbose", action="store_true", help="include compiler diagnostics")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        output = build(root, args.kind, args.compiler, args.verbose)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, "wtop: Windows packaging failed: " + str(error) + "\n")
    print("wtop: Windows bundle ready: " + str(output))


if __name__ == "__main__":
    main()
