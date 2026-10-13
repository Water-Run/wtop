#!/usr/bin/env python3
"""Exercise an installed Windows program through a real console screen buffer."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


def run(executable: Path, harness: Path) -> None:
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
    with tempfile.TemporaryDirectory(prefix="wtop-console-") as temporary:
        environment["XDG_CONFIG_HOME"] = temporary
        environment["TERM"] = "dumb"
        command = subprocess.list2cmdline([str(executable.resolve()), "--lang", "en-US", "--no-color"])
        # The Host tile can be below the visible Overview panels at 80x25.
        # Memory is part of the default visible layout on every tested host.
        steps = ("await:20000:Memory,snap:overview,key:2,await:10000:Command,snap:processes,"
                 "resize:100x30,key:6,await:10000:Sockets,snap:network,"
                 "key:9,await:10000:Kernel,snap:system,key:q,exit:10000")
        result = subprocess.run([str(harness.resolve()), steps, command], env=environment,
                                cwd=temporary, capture_output=True, timeout=75)
        output = result.stdout.decode("utf-8", errors="replace").replace("\r\n", "\n")
        assert result.returncode == 0, output + result.stderr.decode(errors="replace")
        assert "process exited, exit code 0" in output, output
        assert "terminated a process" not in output and "\x1b" not in output, output
        screens = {name: screen for name, screen in re.findall(
            r"^===== (\w+) [^\n]+\n(.*?)(?=^-----|\Z)", output, re.M | re.S)}
        for name, markers in {"overview": ("CPU", "Memory"), "processes": ("PID", "Command"),
                              "network": ("Interfaces", "Sockets"), "system": ("Host", "Kernel")}.items():
            assert all(marker in screens.get(name, "") for marker in markers), output
            print("Windows console " + name + ": ok")
        print("Windows console resize and clean exit: ok")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--harness", type=Path, required=True)
    args = parser.parse_args()
    run(args.executable, args.harness)
