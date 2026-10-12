#!/usr/bin/env python3
"""Create and verify a complete Linux release archive, including hidden files."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile


REQUIRED = (
    "wtop/wtop", "wtop-onefile", "wtop/.luai/native/wtop_native.so",
    "wtop/LICENSE", "wtop/THIRD_PARTY_NOTICES.md",
    "wtop/.luai/licenses/Lua-MIT.txt", "wtop/.luai/licenses/LGPL-3.0-or-later.txt",
    "SHA256SUMS", "SBOM.cyclonedx.json", "BASELINE.release.txt",
)
TRANSPORT_MANIFEST = "RELEASE-SHA256SUMS"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_name(name: str) -> bool:
    path = PurePosixPath(name)
    return (bool(path.parts) and not path.is_absolute() and ".." not in path.parts
            and "\\" not in name and "\n" not in name and "\r" not in name
            and str(path) == name)


def read_manifest(data: bytes) -> dict[str, str]:
    result = {}
    for line in data.decode("utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or not safe_name(match[2]) or match[2] in result:
            raise ValueError("invalid or duplicate checksum entry")
        result[match[2]] = match[1]
    if not result:
        raise ValueError("empty checksum manifest")
    return result


def check_payload(files: dict[str, bytes], modes: dict[str, int]) -> None:
    for name in REQUIRED:
        if name not in files:
            raise ValueError("release is missing " + name)
    if any(mode & 0o7000 or mode & 0o444 != 0o444 for mode in modes.values()):
        raise ValueError("release file has unsafe or unreadable permissions")
    manifest = read_manifest(files["SHA256SUMS"])
    expected = {name for name in files if name.startswith("wtop/")}
    expected.add("wtop-onefile")
    if set(manifest) != expected:
        raise ValueError("SHA256SUMS does not cover exactly the complete bundle")
    for name, claimed in manifest.items():
        if digest(files[name]) != claimed:
            raise ValueError("checksum mismatch: " + name)
    for name in ("wtop/wtop", "wtop-onefile", "wtop/.luai/native/wtop_native.so"):
        if modes[name] & 0o555 != 0o555:
            raise ValueError("release executable lost its permissions: " + name)
    sbom = json.loads(files["SBOM.cyclonedx.json"])
    hashes = {entry["content"] for component in sbom.get("components", [])
              for entry in component.get("hashes", []) if entry.get("alg") == "SHA-256"}
    if not hashes or not hashes.issubset(set(manifest.values())):
        raise ValueError("SBOM disagrees with the bundle manifest")
    if "status: within the promised floor" not in files["BASELINE.release.txt"].decode():
        raise ValueError("release baseline has no passing verdict")


def manifest_bytes(files: dict[str, bytes]) -> bytes:
    return "".join(digest(data) + "  " + name + "\n"
                   for name, data in sorted(files.items())).encode("utf-8")


def create(dist: Path, output: Path, epoch: int = 0) -> None:
    files, modes = {}, {}
    for path in sorted((dist / "wtop").rglob("*")):
        if path.is_symlink():
            raise ValueError("release contains a symlink: " + str(path))
        if path.is_file():
            name = path.relative_to(dist).as_posix()
            files[name], modes[name] = path.read_bytes(), stat.S_IMODE(path.stat().st_mode)
    for name in REQUIRED:
        if not name.startswith("wtop/"):
            path = dist / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("release is missing a regular file: " + name)
            files[name], modes[name] = path.read_bytes(), stat.S_IMODE(path.stat().st_mode)
    check_payload(files, modes)
    files[TRANSPORT_MANIFEST], modes[TRANSPORT_MANIFEST] = manifest_bytes(files), 0o644
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".wtop-archive-", delete=False) as temporary:
        staging = Path(temporary.name)
        try:
            with gzip.GzipFile(fileobj=temporary, mode="wb", filename="", mtime=epoch) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    for name, data in sorted(files.items()):
                        if not safe_name(name):
                            raise ValueError("invalid release path: " + name)
                        member = tarfile.TarInfo(name)
                        member.size, member.mode, member.mtime = len(data), modes[name], epoch
                        archive.addfile(member, io.BytesIO(data))
            temporary.flush()
            os.fsync(temporary.fileno())
            staging.replace(output)
        finally:
            staging.unlink(missing_ok=True)
    checksum = output.with_name(output.name + ".sha256")
    checksum.write_text(digest(output.read_bytes()) + "  " + output.name + "\n")
    print("release archive: " + str(output))


def inspect(archive_path: Path) -> tuple[dict[str, bytes], dict[str, int]]:
    files, modes = {}, {}
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            if not member.isfile() or not safe_name(member.name) or member.name in files:
                raise ValueError("unsafe or duplicate archive member: " + member.name)
            if member.size > 128 * 1024 * 1024 or sum(map(len, files.values())) + member.size > 512 * 1024 * 1024:
                raise ValueError("release archive exceeds the size limit")
            files[member.name] = archive.extractfile(member).read()
            modes[member.name] = member.mode
    if TRANSPORT_MANIFEST not in files:
        raise ValueError("release archive has no transport manifest")
    manifest = read_manifest(files[TRANSPORT_MANIFEST])
    if set(manifest) != set(files) - {TRANSPORT_MANIFEST}:
        raise ValueError("transport manifest does not cover exactly the archive")
    for name, claimed in manifest.items():
        if digest(files[name]) != claimed:
            raise ValueError("archive checksum mismatch: " + name)
    check_payload(files, modes)
    return files, modes


def verify(archive_path: Path, repository: Path, version: str, pty: str) -> None:
    claimed = read_manifest(archive_path.with_name(archive_path.name + ".sha256").read_bytes())
    if claimed != {archive_path.name: digest(archive_path.read_bytes())}:
        raise ValueError("downloaded archive digest disagrees with its checksum file")
    files, modes = inspect(archive_path)
    with tempfile.TemporaryDirectory(prefix="wtop-download-") as directory:
        root = Path(directory)
        for name, data in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(modes[name])
        for executable in (root / "wtop/wtop", root / "wtop-onefile"):
            subprocess.run([sys.executable, str(repository / "tests/installed_smoke.py"),
                            "--executable", str(executable), "--version", version,
                            "--platform", "Linux"], check=True, timeout=180)
            environment = os.environ.copy()
            environment.update(WTOP_EXECUTABLE=str(executable), WTOP_ROOT=str(repository),
                               WTOP_PTY_PROFILE=pty)
            subprocess.run([sys.executable, str(repository / "tests/pty_smoke.py")],
                           cwd=directory, env=environment, check=True, timeout=600)
    print("downloaded archive integrity, native identity, CLI/JSON and PTY: ok")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("create")
    build.add_argument("--dist", type=Path, default=Path("dist"))
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--epoch", type=int, default=0)
    check = commands.add_parser("verify")
    check.add_argument("archive", type=Path, nargs="?")
    check.add_argument("--download-dir", type=Path)
    check.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    check.add_argument("--version", required=True)
    check.add_argument("--pty", choices=("quick", "full"), default="full")
    args = parser.parse_args()
    try:
        if args.command == "create":
            create(args.dist.resolve(), args.output.resolve(), args.epoch)
        else:
            if args.download_dir:
                candidates = list(args.download_dir.glob("wtop-*-linux-*-glibc.tar.gz"))
                if len(candidates) != 1 or args.archive:
                    raise ValueError("download must contain exactly one platform archive")
                args.archive = candidates[0]
            if args.archive is None:
                raise ValueError("an archive or --download-dir is required")
            verify(args.archive.resolve(), args.repo.resolve(), args.version, args.pty)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("wtop: release archive refused: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
