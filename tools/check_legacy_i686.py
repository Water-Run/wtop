#!/usr/bin/env python3
"""Run an existing ELF32 development tree under an isolated Linux 3.2 guest."""
import argparse
import datetime
import gzip
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import signal
import stat
import subprocess
import urllib.request
from check_linux_i686 import birth, pid_namespace, sha256

ROOT = pathlib.Path(__file__).resolve().parents[1]
KERNEL_URL = ("https://archive.debian.org/debian-security/pool/updates/main/l/linux/"
              "linux-image-3.2.0-6-686-pae_3.2.102-1_i386.deb")
KERNEL_SHA256 = "2f4a856fab53d9834a43b6db12d288f978224806f2f5f2055e91dbcfefc0445e"


def cpio(entries):
    archive = bytearray()
    rows = list(sorted(entries.items(), key=lambda item: (item[0].count("/"), item[0])))
    rows.append(("TRAILER!!!", (0, b"", 0, 0)))
    for index, (name, (mode, body, major, minor)) in enumerate(rows, 1):
        encoded = (name + "\0").encode("utf-8")
        fields = [index, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0,
                  len(body), 0, 0, major, minor, len(encoded), 0]
        archive.extend(b"070701" + b"".join(("%08x" % value).encode() for value in fields) + encoded)
        archive.extend(b"\0" * (-len(archive) % 4))
        archive.extend(body)
        archive.extend(b"\0" * (-len(archive) % 4))
    archive.extend(b"\0" * (-len(archive) % 512))
    return bytes(archive)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-tree", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--cc", default="gcc")
    args = parser.parse_args()
    tree, output = args.runtime_tree.resolve(), args.output.resolve()
    if output.exists():
        parser.error("output exists; inspect its status or select a fresh directory")
    for executable in (args.cc, "qemu-system-i386", "dpkg-deb"):
        if not shutil.which(executable):
            parser.error("required executable not found: " + executable)
    interpreters = list((tree / ".tools").glob("lua-*/bin/lua"))
    if len(interpreters) != 1:
        parser.error("runtime tree must contain one project Lua interpreter")
    lua = interpreters[0]
    images = [lua] + [tree / "build/native" / name for name in
                     ("wtop_native.so", "wtop_hardware_worker", "wtop_gpu_worker")]
    for path in images:
        with path.open("rb") as stream:
            if stream.read(5) != b"\x7fELF\x01":
                parser.error("expected an ELF32 image: " + str(path))
    output.mkdir(parents=True)
    state = {"pid": os.getpid(), "birth": birth(os.getpid()), "pid_namespace": pid_namespace(),
             "terminal": False, "stages": {}, "virtual_CPU": "pentium3",
             "network": False, "host_disks": False, "device_passthrough": False,
             "physical_hardware_verified": False,
             "application_images": {str(path.relative_to(tree)): sha256(path) for path in images}}

    def save():
        state["updated_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        staged = output / "status.json.tmp"
        staged.write_text(json.dumps(state, indent=2) + "\n")
        staged.replace(output / "status.json")

    def run(label, command, environment=None, timeout=None):
        state["current"] = label
        save()
        log = output / (label + ".log")
        with log.open("xb") as stream:
            process = subprocess.Popen(command, cwd=str(ROOT), env=environment,
                stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            state["child"] = {"pid": process.pid, "birth": birth(process.pid)}
            save()
            try:
                code = process.wait(timeout=timeout)
            except BaseException:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                state["stages"][label] = {"actual_exit": process.returncode, "interrupted": True}
                save()
                raise
        state["stages"][label] = {"actual_exit": code, "log_sha256": sha256(log)}
        save()
        print(label + ": " + str(code), flush=True)
        if code:
            raise RuntimeError(label + " failed; see " + str(log))
        return log

    def interrupted(signum, frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    save()
    try:
        run("resources", ["sh", str(ROOT / "tools/check_resources.sh"), "build"])
        package = output / "kernel.deb"
        cache = ROOT / ".tools/downloads/linux-image-3.2.102-i386.deb"
        if cache.is_file() and sha256(cache) == KERNEL_SHA256:
            shutil.copyfile(str(cache), str(package))
        else:
            with urllib.request.urlopen(KERNEL_URL, timeout=45) as source, package.open("xb") as target:
                size = 0
                while True:
                    block = source.read(65536)
                    if not block:
                        break
                    size += len(block)
                    if size > 67108864:
                        raise RuntimeError("kernel package exceeds bound")
                    target.write(block)
        if sha256(package) != KERNEL_SHA256:
            raise RuntimeError("official archive kernel checksum mismatch")
        state["kernel_package_sha256"] = KERNEL_SHA256
        run("kernel_extract", ["dpkg-deb", "-x", str(package), str(output / "kernel")])
        kernel = output / "kernel/boot/vmlinuz-3.2.0-6-686-pae"
        run("guest_init", [args.cc, "-m32", "-static", "-D_FILE_OFFSET_BITS=64",
            "-std=c17", "-O2", "-Wall", "-Wextra", "-Werror",
            str(ROOT / "tests/native/legacy_linux_init.c"), "-lutil", "-o", str(output / "init")])
        env = dict(os.environ, LUA_PATH=str(tree / "src/?.lua") + ";" + str(tree / "src/?/init.lua") + ";;",
                   LUA_CPATH=str(tree / "build/native/?.so") + ";;")
        run("PM_fixture", [str(lua), str(ROOT / "tests/native/recording_fixture.lua"),
            str(output / "pm.wtop"), "runtime-pm"], env)
        entries = {}

        def add(name, mode, body=b"", major=0, minor=0):
            entries[name] = (mode, body, major, minor)

        def add_file(name, path, mode=0o644):
            add(name, stat.S_IFREG | mode, path.read_bytes())

        for name in ("dev", "proc", "sys", "tmp", "out", "etc", "lib", "lib32", "usr",
                     "usr/lib", "usr/lib/locale", "wtop", "wtop/build", "wtop/build/native", "wtop/src"):
            add(name, stat.S_IFDIR | (0o1777 if name == "tmp" else 0o755))
        add("dev/console", stat.S_IFCHR | 0o600, major=5, minor=1)
        add_file("init", output / "init", 0o755)
        for library, destination in (("libc.so.6", "lib32/libc.so.6"),
                                     ("libm.so.6", "lib32/libm.so.6"),
                                     ("ld-linux.so.2", "lib/ld-linux.so.2")):
            path = subprocess.check_output([args.cc, "-m32", "-print-file-name=" + library]).decode().strip()
            source = pathlib.Path(path)
            if not source.is_file() or source.read_bytes()[:5] != b"\x7fELF\x01":
                raise RuntimeError("compiler did not locate ELF32 " + library)
            add_file(destination, source, 0o755)
        locale = pathlib.Path("/usr/lib/locale/C.utf8")
        if not locale.is_dir():
            raise RuntimeError("C.utf8 character locale is required for the UTF-8 guest")
        for base, prefix in ((locale, "usr/lib/locale/C.utf8"), (tree / "src", "wtop/src")):
            add(prefix, stat.S_IFDIR | 0o755)
            for path in sorted(base.rglob("*")):
                name = prefix + "/" + str(path.relative_to(base))
                if path.is_symlink():
                    add(name, stat.S_IFLNK | 0o777, os.readlink(str(path)).encode())
                elif path.is_dir():
                    add(name, stat.S_IFDIR | 0o755)
                elif path.is_file():
                    add_file(name, path)
        add_file("wtop/lua", lua, 0o755)
        for path in images[1:]:
            add_file("wtop/build/native/" + path.name, path, 0o755)
        add_file("wtop/check_guest.lua", ROOT / "tests/native/legacy_linux_probe.lua")
        add_file("wtop/pm.wtop", output / "pm.wtop")
        add("etc/passwd", stat.S_IFREG | 0o644, b"root:x:0:0:root:/tmp:/bin/sh\n")
        add("etc/group", stat.S_IFREG | 0o644, b"root:x:0:\n")
        add("etc/nsswitch.conf", stat.S_IFREG | 0o644, b"passwd: files\ngroup: files\nhosts: files\n")
        ram = output / "initramfs.cpio.gz"
        compressed = io.BytesIO()
        with gzip.GzipFile(filename="", mode="wb", fileobj=compressed, mtime=0) as stream:
            stream.write(cpio(entries))
        ram.write_bytes(compressed.getvalue())
        state["initramfs_sha256"] = sha256(ram)
        state["guest_files_sha256"] = {name: hashlib.sha256(row[1]).hexdigest() for name, row in entries.items()}
        save()
        serial = run("QEMU", ["qemu-system-i386", "-accel", "tcg", "-cpu", "pentium3",
            "-smp", "1", "-m", "256", "-nodefaults", "-display", "none", "-serial", "stdio",
            "-monitor", "none", "-nic", "none", "-no-reboot", "-kernel", str(kernel),
            "-initrd", str(ram), "-append", "console=ttyS0,115200n8 rdinit=/init panic=5"], timeout=300)
        text = serial.read_text(errors="replace")
        cases = re.findall(r"WTOP_GUEST_CASE ([A-Za-z_]+) exit=(\d+)", text)
        tty = re.search(r"WTOP_GUEST_TTY exit=(\d+) bytes=(\d+)", text)
        if len(cases) != 8 or any(code != "0" for _, code in cases) or not tty or tty.group(1) != "0" \
                or "WTOP_GUEST_RESULT PASSED" not in text:
            raise RuntimeError("guest acceptance incomplete; see QEMU.log")
        state.update(terminal=True, success=True, current=None, guest_cases=dict(cases),
                     TTY_bytes=int(tty.group(2)), guest_kernel_32bit_verified=True)
        save()
        print("LEGACY_LINUX_I686_PASSED: Linux3.2/Pentium3/noSSE2; virtual environment only", flush=True)
    except BaseException as error:
        state.update(terminal=True, success=False, error_type=type(error).__name__)
        save()
        raise


if __name__ == "__main__":
    main()
