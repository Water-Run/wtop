#!/usr/bin/env python3
"""Compile the Windows payload encoding and compare every emitted byte."""

from pathlib import Path
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import package_windows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default=os.environ.get("WTOP_LUA", "lua"))
    parser.add_argument("--compiler", default="cc")
    args = parser.parse_args()
    compiler = shutil.which(args.compiler)
    assert compiler, "a C compiler is required"
    with tempfile.TemporaryDirectory(prefix="wtop-payload-test-") as directory:
        stage = Path(directory)
        module = stage / "luainstaller/src/onefile.lua"
        module.parent.mkdir(parents=True)
        original = "local function emitFileArrays(files)\nreturn 'old'\nend\n\nlocal EXTRACTOR_TEMPLATE = 'unchanged'\nreturn emitFileArrays\n"
        module.write_bytes(original.encode("utf-8"))
        try:
            package_windows.prepare_onefile_payload(ROOT, stage)
        except ValueError:
            pass
        else:
            raise AssertionError("modified dependency source was accepted")
        assert module.read_text() == original
        with patch.object(package_windows, "ONEFILE_SOURCE_SHA256", hashlib.sha256(original.encode()).hexdigest()):
            package_windows.prepare_onefile_payload(ROOT, stage)
        generator = stage / "generate.lua"
        generator.write_text('''local emit = assert(dofile(arg[1]))
local bytes = {}
for n = 0, 255 do bytes[#bytes + 1] = string.char(n) end
local all = table.concat(bytes)
local files = { { content = "" }, { content = all },
    { content = string.rep(string.char(0, 255, 34, 92, 10, 63, 55, 56, 57), 513) },
    { content = string.rep(all, 32768) } }
io.write("#include <stdio.h>\\n#ifdef _WIN32\\n#include <io.h>\\n#include <fcntl.h>\\n#endif\\n", emit(files), "\\nint main(void) {\\n")
io.write("#ifdef _WIN32\\nif (_setmode(_fileno(stdout), _O_BINARY) == -1) return 12;\\n#endif\\n")
for n, file in ipairs(files) do
    io.write(string.format("if (sizeof(luai_file_%d) != %d) return 10;\\n", n, #file.content + 1))
    io.write(string.format("if (fwrite(luai_file_%d, 1, %d, stdout) != %d) return 11;\\n", n, #file.content, #file.content))
end
io.write("return 0; }\\n")
''', encoding="utf-8")
        source = stage / "payload.c"
        with source.open("wb") as output:
            subprocess.run([args.lua, str(generator), str(module)], stdout=output, check=True, timeout=60)

        def bounded_memory():
            import resource
            resource.setrlimit(resource.RLIMIT_AS, (1024 * 1024 * 1024,) * 2)

        executable = stage / ("payload.exe" if os.name == "nt" else "payload")
        environment = dict(os.environ)
        environment["PATH"] = str(Path(compiler).parent) + os.pathsep + environment.get("PATH", "")
        subprocess.run([compiler, "-std=c99", "-Wall", "-Wextra", "-Werror", "-Os", str(source), "-o", str(executable)],
                       env=environment, check=True, timeout=120,
                       preexec_fn=bounded_memory if sys.platform.startswith("linux") else None)
        result = subprocess.check_output([str(executable)], timeout=20)
        all_bytes = bytes(range(256))
        expected = all_bytes + bytes([0, 255, 34, 92, 10, 63, 55, 56, 57]) * 513 + all_bytes * 32768
        assert result == expected, "payload bytes changed"
        print("Windows payload: exact empty/all-byte/NUL/escape/chunk/8MiB round trips; compiler limited to1GiB onLinux")


if __name__ == "__main__":
    main()
