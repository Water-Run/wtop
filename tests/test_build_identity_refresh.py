#!/usr/bin/env python3
"""Exercise incremental identity updates through the real Linux Make rules."""
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(command, cwd):
    result = subprocess.run(command, cwd=str(cwd), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, universal_newlines=True)
    if result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()


def build(tree, compiler):
    native = tree / "build/native"
    return run(["make", "--no-print-directory", "native",
        "CC=" + compiler, "NATIVE_SOURCES=" + str(tree / "identity.c"),
        "NATIVE_HEADERS=", "LUA_PREFIX=" + str(tree / "lua"),
        "GPU_WORKER_HEADER=" + str(native / "unused-gpu.h"),
        "HARDWARE_WORKER_HEADER=" + str(native / "unused-hardware.h"),
        "-o", str(native / "unused-gpu.h"),
        "-o", str(native / "unused-hardware.h")], tree)


def main():
    if not sys.platform.startswith("linux") or not shutil.which("git"):
        print("SKIP: Linux build-identity regression requires Linux and Git")
        return
    compiler = os.environ.get("CC", "cc")
    cc = shlex.split(compiler)
    with tempfile.TemporaryDirectory(prefix="wtop-identity-") as temporary:
        tree = pathlib.Path(temporary) / "checkout"
        (tree / "tools").mkdir(parents=True)
        (tree / "src/wtop").mkdir(parents=True)
        (tree / "lua").mkdir()
        (tree / "lua/.wtop-ready").touch()
        native = tree / "build/native"
        native.mkdir(parents=True)
        for name in ("unused-gpu.h", "unused-hardware.h"):
            (native / name).touch()
        shutil.copy2(ROOT / "Makefile", tree / "Makefile")
        shutil.copy2(ROOT / "tools/write_build_id.sh", tree / "tools/write_build_id.sh")
        shutil.copy2(ROOT / "tools/check_resources.sh", tree / "tools/check_resources.sh")
        shutil.copy2(ROOT / "tools/bootstrap_lua.sh", tree / "tools/bootstrap_lua.sh")
        (tree / "VERSION").write_text("2.7.1\n")
        (tree / "identity.c").write_text(
            '#include "build_revision.h"\n#include "build_version.h"\n'
            'const char *probe_revision(void) { return WTOP_BUILD_REVISION; }\n'
            'const char *probe_version(void) { return WTOP_VERSION; }\n')
        (tree / "probe.c").write_text(
            '#include <dlfcn.h>\n#include <stdio.h>\n'
            'int main(int argc, char **argv) {\n'
            '  if (argc != 2) return 2;\n'
            '  void *module = dlopen(argv[1], RTLD_NOW);\n'
            '  if (!module) return 3;\n'
            '  const char *(*revision)(void) = dlsym(module, "probe_revision");\n'
            '  const char *(*version)(void) = dlsym(module, "probe_version");\n'
            '  if (!revision || !version) return 4;\n'
            '  printf("%s|%s\\n", revision(), version());\n'
            '  return dlclose(module) != 0;\n}\n')
        run(cc + [str(tree / "probe.c"), "-ldl", "-o", str(tree / "probe")], tree)
        run(["git", "init", "-q", "--template="], tree)
        run(["git", "symbolic-ref", "HEAD", "refs/heads/main"], tree)
        run(["git", "config", "user.name", "wtop fixture"], tree)
        run(["git", "config", "user.email", "fixture@example.invalid"], tree)
        run(["git", "config", "commit.gpgsign", "false"], tree)
        (tree / ".git/empty-hooks").mkdir()
        run(["git", "config", "core.hooksPath", str(tree / ".git/empty-hooks")], tree)
        run(["git", "add", "VERSION"], tree)
        run(["git", "commit", "-qm", "fixture initial identity"], tree)
        build(tree, compiler)
        first = run(["git", "describe", "--always", "--dirty", "--tags"], tree)
        module = native / "wtop_native.so"
        assert run([str(tree / "probe"), str(module)], tree) == first + "|2.7.1"
        unchanged = {str(p): p.stat().st_mtime_ns for p in (
            module, native / "build_revision.h", native / "build_version.h",
            tree / "src/wtop/build_id.lua", tree / "src/wtop/version.lua")}
        build(tree, compiler)
        assert all(pathlib.Path(name).stat().st_mtime_ns == stamp
                   for name, stamp in unchanged.items()), "unchanged build recompiled or rewrote identity"
        (tree / "marker").write_text("new revision, unchanged native source\n")
        run(["git", "add", "marker"], tree)
        run(["git", "commit", "-qm", "fixture updated identity"], tree)
        second = run(["git", "describe", "--always", "--dirty", "--tags"], tree)
        assert second != first
        build(tree, compiler)
        assert run([str(tree / "probe"), str(module)], tree) == second + "|2.7.1", \
            "native module retained the preceding Git identity"
        transport = pathlib.Path(temporary) / "transport"
        shutil.copytree(str(tree), str(transport), ignore=shutil.ignore_patterns(".git"))
        transported_module = transport / "build/native/wtop_native.so"
        build(transport, compiler)
        assert run([str(transport / "probe"), str(transported_module)], transport) == second + "|2.7.1"
        (transport / "VERSION").write_text("2.7.2\n")
        build(transport, compiler)
        assert run([str(transport / "probe"), str(transported_module)], transport) == second + "|2.7.2", \
            "transport refresh lost provenance or failed to update VERSION"
    print("BUILD_ID_REFRESH_PASSED: Git update, unchanged mtimes, native reload and no-Git transport")


if __name__ == "__main__":
    main()
