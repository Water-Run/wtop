#!/usr/bin/env python3
"""Check the CLI and native identity of an installed or unpacked program."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from json_contract_smoke import validate


def run_checks(executable: Path, version: str, platform: str) -> None:
    environment = os.environ.copy()
    for name in list(environment):
        if name.startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT")):
            environment.pop(name)
    with tempfile.TemporaryDirectory(prefix="wtop-installed-") as directory:
        for arguments in (("--version",), ("--diagnose",), ("--snapshot",), ("--agent",), ("--report",),
                          ("--memory-bandwidth", "--memory-pmu", "list"),
                          ("--memory-bandwidth", "--safe-mode"), ("--memory-bandwidth",)):
            mode = arguments[0]
            result = subprocess.run([str(executable), *arguments], cwd=directory,
                                    env=environment, capture_output=True, timeout=30)
            assert result.returncode == 0, "%s exited %d: %s" % (
                mode, result.returncode, result.stderr.decode(errors="replace")[:500])
            output = result.stdout.decode("utf-8").replace("\r\n", "\n")
            if mode == "--version":
                assert re.fullmatch(r"wtop " + re.escape(version)
                                    + r"(?: \(rev [^)]+\))?\n", output), output
            elif mode == "--diagnose":
                assert re.search(r"^  Platform: " + re.escape(platform) + r"(?: |$)",
                                 output, re.MULTILINE), "wrong platform"
                assert re.search(r"^  Native: +available \(" + re.escape(version) + r"\)$",
                                 output, re.MULTILINE), "missing or mismatched native version"
            elif mode in ("--snapshot", "--agent"):
                validate(json.loads(output), mode[2:])
            elif mode == "--memory-bandwidth":
                document = json.loads(output)
                validate(document, "memory-bandwidth")
                assert document["platform"] == platform
                if "--safe-mode" in arguments and platform == "Linux":
                    assert document["status"] != "ok"
            else:
                assert output.startswith("# "), "hardware report has no title"
            print("installed %s: ok" % " ".join(arguments))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--platform", choices=("Linux", "Darwin", "Windows"), required=True)
    args = parser.parse_args()
    run_checks(args.executable.resolve(), args.version, args.platform)


if __name__ == "__main__":
    main()
