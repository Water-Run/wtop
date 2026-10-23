#!/usr/bin/env python3
"""Build and check an ELF32 development tree without replacing the host build."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]

def lua_pin(tree):
    bootstrap = (tree / "tools/bootstrap_lua.sh").read_text()
    versions = re.findall(r"^version=([0-9.]+)$", bootstrap, re.MULTILINE)
    checksums = re.findall(r"^sha256=([0-9a-f]{64})$", bootstrap, re.MULTILINE)
    makefile = (tree / "Makefile").read_text()
    declared = re.findall(r"^LUA_VERSION\s*:=\s*([0-9.]+)$", makefile, re.MULTILINE)
    if len(versions) != 1 or len(checksums) != 1 or declared != versions:
        raise RuntimeError("Lua bootstrap pin must match the checked-out Makefile")
    return versions[0], checksums[0]


def birth(pid):
    try:
        return pathlib.Path("/proc", str(pid), "stat").read_text().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def pid_namespace():
    try:
        return os.readlink("/proc/self/ns/pid")
    except OSError:
        return None


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            block = stream.read(1048576)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "build/linux-i686")
    parser.add_argument("--cc", default="gcc", help="compiler executable with multilib support")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--legacy-kernel", action="store_true",
                        help="also run the Linux 3.2/Pentium III QEMU development guest")
    args = parser.parse_args()
    if not sys.platform.startswith("linux") or not 1 <= args.jobs <= 64:
        parser.error("Linux and --jobs in 1..64 are required")
    compiler = shutil.which(args.cc)
    if not compiler:
        parser.error("compiler not found: " + args.cc)
    output = args.output.resolve()
    if output.exists():
        parser.error("output already exists; inspect its status or select a fresh --output")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=str(ROOT)).decode().strip()
    output.mkdir(parents=True)
    state = {"pid": os.getpid(), "birth": birth(os.getpid()), "head": head,
             "terminal": False, "stages": {}, "development_only": True,
             "real_32bit_kernel_verified": False,
             "pid_namespace": pid_namespace()}
    tree = output / "tree"
    env = dict(os.environ)

    def interrupted(signum, frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)

    def save():
        state["updated_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        staged = output / "status.json.tmp"
        staged.write_text(json.dumps(state, indent=2) + "\n")
        staged.replace(output / "status.json")

    def run(label, command, cwd=ROOT, environment=None):
        state["current"] = label
        save()
        log = output / (label + ".log")
        with log.open("xb") as stream:
            process = subprocess.Popen(command, cwd=str(cwd), env=environment,
                                       start_new_session=True,
                                       stdout=stream, stderr=subprocess.STDOUT)
            state["child"] = {"pid": process.pid, "birth": birth(process.pid)}
            save()
            try:
                code = process.wait()
            except BaseException:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                state["stages"][label] = {"actual_exit": process.returncode,
                                           "interrupted": True}
                save()
                raise
        state["stages"][label] = {"actual_exit": code, "log_sha256": sha256(log)}
        save()
        print(label + ": " + str(code), flush=True)
        if code:
            raise RuntimeError(label + " failed; see " + str(log))

    save()
    try:
        run("resources", ["sh", str(ROOT / "tools/check_resources.sh"), "full"])
        run("checkout", ["git", "worktree", "add", "--detach", str(tree), head])
        lua_version, lua_sha256 = lua_pin(tree)
        state.update(Lua_version=lua_version, Lua_sha256=lua_sha256)
        save()
        cc = output / "cc32"
        cc.write_text("#!/bin/sh\nexec " + shlex.quote(compiler)
                      + ' -std=gnu99 -m32 -D_FILE_OFFSET_BITS=64 "$@"\n')
        cc.chmod(0o755)
        probe = output / "abi.c"
        probe.write_text('#include <sys/types.h>\n#include <stdint.h>\n'
                         'int main(void) { return sizeof(void*) != 4 || '
                         'sizeof(uint64_t) != 8 || sizeof(off_t) != 8; }\n')
        run("compiler", [str(cc), str(probe), "-o", str(output / "abi")])
        run("ABI", [str(output / "abi")])
        archive = output / ("lua-" + lua_version + ".tar.gz")
        cached = ROOT / ".tools/downloads" / archive.name
        if cached.is_file() and sha256(cached) == lua_sha256:
            shutil.copyfile(str(cached), str(archive))
        else:
            with urllib.request.urlopen("https://www.lua.org/ftp/" + archive.name, timeout=45) as source:
                with archive.open("xb") as target:
                    total = 0
                    while True:
                        block = source.read(65536)
                        if not block:
                            break
                        total += len(block)
                        if total > 16777216:
                            raise RuntimeError("Lua archive exceeds download bound")
                        target.write(block)
        if sha256(archive) != lua_sha256:
            raise RuntimeError("pinned Lua checksum mismatch")
        source_dir = output / "lua-source"
        source_dir.mkdir()
        run("extract", ["tar", "-xzf", str(archive), "-C", str(source_dir)])
        lua_source = source_dir / ("lua-" + lua_version)
        prefix = tree / ".tools" / ("lua-" + lua_version)
        run("Lua32", ["make", "-C", str(lua_source), "-j" + str(args.jobs), "linux",
                       "CC=" + str(cc), "MYCFLAGS=-fPIC"])
        run("install_private", ["make", "-C", str(lua_source), "install", "INSTALL_TOP=" + str(prefix)])
        (prefix / ".wtop-ready").touch()
        env.update(CC=str(cc), WTOP_LUA=str(prefix / "bin/lua"), WTOP_ROOT=str(tree),
                   LUA_PATH=str(tree / "src/?.lua") + ";" + str(tree / "src/?/init.lua") + ";;",
                   LUA_CPATH=str(tree / "build/native/?.so") + ";;",
                   LANG="C.UTF-8", LC_ALL="C.UTF-8", WTOP_TESTS_WITHOUT_ARTIFACTS="1")
        run("native32", ["make", "native", "CC=" + str(cc)], tree, env)
        lua = str(prefix / "bin/lua")
        images = [prefix / "bin/lua", tree / "build/native/wtop_native.so",
                  tree / "build/native/wtop_hardware_worker", tree / "build/native/wtop_gpu_worker"]
        for path in images:
            with path.open("rb") as stream:
                if stream.read(5) != b"\x7fELF\x01":
                    raise RuntimeError("expected ELF32: " + str(path))
        state["ELF32_sha256"] = {str(path.relative_to(tree)): sha256(path) for path in images}
        save()
        run("module_ABI", [lua, "-e", 'assert(string.packsize("T")==4 and string.packsize("j")==8 '
            'and require("wtop.native").available)'], tree, env)
        run("baseline", ["sh", "tools/record_baseline.sh", "build/native/wtop_native.so",
                         str(prefix / "bin/lua")], tree, env)
        run("identity", ["make", "test-build-identity", "CC=" + str(cc)], tree, env)
        files = sorted(str(path.relative_to(tree)) for group in ("unit", "integration")
                       for path in (tree / "tests" / group).glob("test_*.lua"))
        state["Lua_files"] = len(files)
        run("Lua_tests", [lua, "tests/run.lua"] + files, tree, env)
        run("recording", ["python3", "tests/test_recording_replay.py", "--lua", lua,
                          "--output-dir", str(output / "recording")], tree, env)
        for label, script in (("health_TTY", "test_health_tty.py"),
                              ("replay_TTY", "test_recording_replay_tty.py"),
                              ("runtime_PM_TTY", "test_runtime_pm_tty.py")):
            run(label, ["python3", "tests/" + script, "--lua", lua, "--guard",
                        "--output-dir", str(output / label)], tree, env)
        ascii_env = dict(env, LANG="C", LC_ALL="C")
        run("C_locale", [lua, "-e", 'local n=require("wtop.native"); '
            'assert(n.wcwidth(65)==1 and n.wcwidth(0x4E2D)==-1)'], tree, ascii_env)
        if args.legacy_kernel:
            run("legacy_kernel", ["python3", str(ROOT / "tools/check_legacy_i686.py"),
                "--runtime-tree", str(tree), "--output", str(output / "legacy-kernel"),
                "--cc", str(cc)], tree, env)
        state.update(terminal=True, success=True, current=None)
        save()
        print("LINUX_I686_DEVELOPMENT_CHECK_PASSED: " + str(output), flush=True)
    except BaseException as error:
        state.update(terminal=True, success=False, error_type=type(error).__name__)
        save()
        raise


if __name__ == "__main__":
    main()
