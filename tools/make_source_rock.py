#!/usr/bin/env python3
"""Build a version rockspec and source artifacts from tracked working sources."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import stat
import subprocess
import tarfile
import zipfile


def generate_rockspec(root: Path) -> tuple[str, Path]:
    version = (root / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", version):
        raise ValueError("VERSION must be a release version")
    source = (root / "wtop-scm-1.rockspec").read_text()
    source, count = re.subn(r'^version = "scm-1"$', 'version = "%s-1"' % version,
                            source, flags=re.MULTILINE)
    if count != 1:
        raise ValueError("development rockspec must declare scm-1 exactly once")
    source, count = re.subn(r'^    branch = "main",$', '    tag = "v%s",\n    dir = "wtop",' % version,
                            source, flags=re.MULTILINE)
    if count != 1:
        raise ValueError("development rockspec must declare main exactly once")
    destination = root / ("wtop-%s-1.rockspec" % version)
    destination.write_text("-- Generated from wtop-scm-1.rockspec and VERSION; DO NOT EDIT.\n" + source)
    return version, destination


def tracked_sources(root: Path, rockspec: Path) -> tuple[dict[str, bytes], dict[str, int], dict]:
    if not (root / ".git").exists():
        raise ValueError("source artifacts must be built from a Git checkout")
    names = subprocess.check_output(["git", "ls-files", "-z", "--cached"], cwd=root).decode().split("\0")
    names = sorted(set(filter(None, names)) | {rockspec.name})
    files, modes = {}, {}
    for name in names:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("tracked source is not a regular file: " + name)
        files[name] = path.read_bytes()
        modes[name] = 0o755 if path.stat().st_mode & 0o111 else 0o644
    # Generated revision files and build products are excluded by the tracked
    # file list. A source rock regenerates its version without claiming Git history.
    metadata = {
        "schema": "dev.waterrun.wtop.source/v1",
        "version": (root / "VERSION").read_text().strip(),
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root)),
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())},
    }
    files["SOURCE.json"] = (json.dumps(metadata, sort_keys=True, indent=2) + "\n").encode()
    modes["SOURCE.json"] = 0o644
    return files, modes, metadata


def build(root: Path, output: Path, require_clean: bool = False) -> list[Path]:
    version, rockspec = generate_rockspec(root)
    files, modes, metadata = tracked_sources(root, rockspec)
    if require_clean and metadata["dirty"]:
        raise ValueError("formal release sources must be committed and clean")
    for required in ("tools/make_source_rock.py", "tools/release_archive.py", "tests/installed_smoke.py"):
        if required not in files:
            raise ValueError("new release sources must be tracked before packaging: " + required)
    output.mkdir(parents=True, exist_ok=True)
    copied_spec = output / rockspec.name
    copied_spec.write_bytes(rockspec.read_bytes())
    tar_path = output / ("wtop-%s.tar.gz" % version)
    with tar_path.open("wb") as target:
        with gzip.GzipFile(fileobj=target, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for name, data in sorted(files.items()):
                    entry = tarfile.TarInfo("wtop-%s/%s" % (version, name))
                    entry.size, entry.mode, entry.mtime = len(data), modes[name], 0
                    archive.addfile(entry, io.BytesIO(data))
    rock_path = output / ("wtop-%s-1.src.rock" % version)
    with zipfile.ZipFile(rock_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        entries = {"wtop/" + name: (data, modes[name]) for name, data in files.items()}
        entries[rockspec.name] = (rockspec.read_bytes(), 0o644)
        for name, (data, mode) in sorted(entries.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(entry, data, compress_type=zipfile.ZIP_DEFLATED)
    result = [copied_spec, tar_path, rock_path]
    (output / "SOURCE-SHA256SUMS").write_text("".join(
        hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n" for path in result))
    print("source artifacts: " + ", ".join(path.name for path in result))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, default=Path("dist/source"))
    parser.add_argument("--rockspec-only", action="store_true")
    parser.add_argument("--require-clean", action="store_true")
    args = parser.parse_args()
    try:
        if args.rockspec_only:
            _, path = generate_rockspec(args.root.resolve())
            print("version rockspec: " + str(path))
        else:
            build(args.root.resolve(), args.output.resolve(), args.require_clean)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit("wtop: source artifacts refused: " + str(error))


if __name__ == "__main__":
    main()
