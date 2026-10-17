#!/usr/bin/env python3
"""Check an existing onefile in owned rootless container filesystems.

Requires rootless Podman and an existing local Linux image with sh, id, stat
and cat. Does not build the program, pull images or alter host settings.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import uuid

from json_contract_smoke import validate


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def capture(command):
    return subprocess.check_output(command, text=True, timeout=20).strip()


def cleanup(podman, name):
    result = subprocess.run([podman, "container", "exists", name],
                            capture_output=True, timeout=15)
    if result.returncode == 0:
        subprocess.run([podman, "rm", "--force", name], check=True,
                       capture_output=True, timeout=20)
        return False
    if result.returncode != 1:
        raise RuntimeError("could not verify container cleanup")
    return True


def container_command(options, stage, name, keep_id):
    command = [options.podman, "run", "--rm", "--pull=never", "--name", name,
               "--network=none", "--cap-drop=all", "--read-only",
               "--pids-limit=128", "--memory=512m", "--security-opt", "label=disable",
               "--tmpfs", "/tmp:rw,nosuid,nodev,exec,size=128m,mode=1777",
               "-v", str(options.executable) + ":/input/wtop-onefile:ro",
               "-v", str(stage) + ":/output:rw"]
    if keep_id:
        command.extend(["--userns=keep-id", "--user", str(os.getuid())])
    return command


def check_cli(options, stage, keep_id):
    name = "wtop-rootless-cli-" + uuid.uuid4().hex[:12]
    command = container_command(options, stage, name, keep_id)
    command.extend(["-i", "--cidfile", str(stage / "cli.cid"),
                    "--entrypoint", "/bin/sh", options.image, "-s"])
    script = ["set -eu", "id -u > /output/euid.txt",
              "stat -c '%u %a' / /tmp > /output/owners.txt",
              "cat /proc/self/uid_map > /output/uid-map.txt"]
    modes = ("version", "diagnose", "snapshot", "agent", "report")
    for mode in modes:
        script.append("/input/wtop-onefile --" + mode + " > /output/" + mode
                      + ".out 2> /output/" + mode + ".stderr")
    try:
        with (stage / "cli.log").open("wb") as log:
            result = subprocess.run(command, input=("\n".join(script) + "\n").encode(),
                                    stdout=log, stderr=subprocess.STDOUT, timeout=60)
        assert result.returncode == 0, "container CLI failed; inspect " + str(stage)
    finally:
        removed = cleanup(options.podman, name)
    assert removed, "CLI container needed forced cleanup"
    uid = os.getuid() if keep_id else 0
    assert (stage / "euid.txt").read_text().strip() == str(uid)
    owners = (stage / "owners.txt").read_text().splitlines()
    assert len(owners) == 2 and all(row.split()[0] == "0" for row in owners)
    mappings = (stage / "uid-map.txt").read_text().splitlines()
    assert mappings and all(len(row.split()) == 3 for row in mappings)
    version = (stage / "version.out").read_text()
    assert re.fullmatch(r"wtop " + re.escape(options.version) + r"(?: \(rev [^)]+\))?\n", version)
    diagnostic = (stage / "diagnose.out").read_text()
    assert "Platform: Linux" in diagnostic
    assert re.search(r"Native: +available \(" + re.escape(options.version) + r"\)", diagnostic)
    for mode in ("snapshot", "agent"):
        validate(json.loads((stage / (mode + ".out")).read_text()), mode)
    assert (stage / "report.out").read_text().startswith("# ")
    return {"uid": uid, "keep_id": keep_id, "cli_modes": list(modes),
            "container_removed": removed,
            "environment_sha256": {name: digest(stage / name) for name in
                                   ("euid.txt", "owners.txt", "uid-map.txt")},
            "stdout_sha256": {mode: digest(stage / (mode + ".out")) for mode in modes}}


def check_tui(options, stage, keep_id):
    os.environ["WTOP_ROOT"] = str(Path(__file__).resolve().parents[1])
    os.environ["WTOP_EXECUTABLE"] = str(stage / "tui-launcher.sh")
    import pty_smoke as pty

    def visible(markers, output, columns, rows):
        if not markers:
            return True
        screen = pty.VirtualScreen(columns, rows)
        screen.feed(bytes(output))
        return all(marker in screen.text() for marker in markers)

    pty._markers_visible = visible
    pty.EXECUTABLE = os.environ["WTOP_EXECUTABLE"]
    records = []
    for columns, rows in ((80, 24), (200, 60)):
        name = "wtop-rootless-tui-" + uuid.uuid4().hex[:12]
        command = container_command(options, stage, name, keep_id)
        command.extend(["-it", "--cidfile", str(stage / (str(columns) + ".cid")),
                        "-e", "TERM=xterm-256color", "--entrypoint",
                        "/input/wtop-onefile", options.image])
        launcher = stage / "tui-launcher.sh"
        launcher.write_text("#!/bin/sh\nexec " + " ".join(shlex.quote(s) for s in command) + ' "$@"\n')
        launcher.chmod(0o700)
        try:
            data = pty.run_session(columns, rows, exercise=False,
                                   cli_options=("--lang", "en-US", "--no-color"), script=[
                (("sleep", 1), ("CPU", "Memory")), (b"2", None),
                (("sleep", 1), ("PID", "Command")), (b"9", None),
                (("sleep", .7), ("Host", "Kernel")), (b"1", None),
                (("sleep", .7), ("CPU", "Memory")), (b"q", None),
            ])
        finally:
            removed = cleanup(options.podman, name)
        assert removed, "TUI container needed forced cleanup"
        raw = stage / (str(columns) + ".pty")
        raw.write_bytes(data)
        screen = pty.VirtualScreen(columns, rows)
        screen.feed(data)
        text = screen.text()
        assert "CPU" in text and "Memory" in text
        path = stage / (str(columns) + ".txt")
        path.write_text(text)
        records.append({"columns": columns, "rows": rows, "clean_exit": True,
                        "container_removed": removed, "pty_sha256": digest(raw),
                        "screen_sha256": digest(path)})
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--image", required=True, help="existing local Linux image ID or name")
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, help="new evidence directory; defaults under build/")
    parser.add_argument("--pty", action="store_true", help="check two TUI sizes for both users")
    options = parser.parse_args()
    assert sys.platform.startswith("linux") and os.geteuid() != 0, "requires a rootless Linux user"
    options.podman = shutil.which("podman")
    assert options.podman, "Podman is required"
    assert capture([options.podman, "info", "--format", "{{.Host.Security.Rootless}}"]) == "true"
    options.executable = options.executable.resolve(strict=True)
    assert options.executable.is_file() and os.access(options.executable, os.X_OK)
    image = capture([options.podman, "image", "inspect", "--format", "{{.Id}} {{.Os}}", options.image]).split()
    assert len(image) == 2 and image[1] == "linux", "requires an existing Linux image"
    options.image = image[0]
    if options.output is None:
        options.output = Path(__file__).resolve().parents[1] / "build" / ("rootless-onefile-" + uuid.uuid4().hex)
    options.output = options.output.resolve()
    options.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    record = {"status": "running", "executable_sha256": digest(options.executable),
              "podman_version": capture([options.podman, "--version"]),
              "image_id": options.image, "rootless": True, "cases": [],
              "scope": "owned container rootfs; does not prove unmapped host-root support"}
    try:
        for keep_id, name in ((False, "container-root"), (True, "keep-id")):
            stage = options.output / name
            stage.mkdir(mode=0o700)
            case = check_cli(options, stage, keep_id)
            if options.pty:
                case["tui"] = check_tui(options, stage, keep_id)
            record["cases"].append(case)
        record["status"] = "passed"
    except BaseException as error:
        record["status"] = "failed"
        record["error_type"] = type(error).__name__
        raise
    finally:
        (options.output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    print("rootless onefile: both users' CLI" + (" and TUI" if options.pty else "")
          + " passed; evidence: " + str(options.output))


if __name__ == "__main__":
    main()
