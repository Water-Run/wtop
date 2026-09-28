#!/usr/bin/env python3
"""Generate a CycloneDX 1.5 SBOM for a wtop bundle directory.

Lists the application itself, the bundled PUC Lua runtime, and the build-time
luainstaller tool, with SHA-256 hashes for the bundle entry points that exist.
Usage: tools/make_sbom.py [--bundle dist/bundle-dir] [--output dist/SBOM.cyclonedx.json]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import uuid


def git_revision(root: pathlib.Path) -> str | None:
    try:
        return subprocess.run(
            ["git", "-C", str(root), "describe", "--always", "--dirty", "--tags"],
            capture_output=True, text=True, check=True,
        ).stdout.strip() or None
    except (OSError, subprocess.CalledProcessError):
        return None


def file_hash(path: pathlib.Path) -> str | None:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def component(identifier: str, name: str, version: str, license_id: str,
              description: str, scope: str = "required",
              hashes: list[dict[str, str]] | None = None) -> dict:
    entry = {
        "bom-ref": identifier,
        "type": "application" if name == "wtop" else "library",
        "name": name,
        "version": version,
        "licenses": [{"license": {"id": license_id}}],
        "purl": f"pkg:generic/{name}@{version}",
        "scope": scope,
        "description": description,
    }
    if hashes:
        entry["hashes"] = hashes
    return entry


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=pathlib.Path,
                        default=pathlib.Path("dist/bundle-dir"),
                        help="bundle directory to describe")
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path("dist/SBOM.cyclonedx.json"),
                        help="where to write the SBOM")
    arguments = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    revision = git_revision(root)
    version = "0.1.0"
    entry_names = ["wtop", "wtop-onefile", "lua", "lua55.dll", "wtop_native.dll",
                   "wtop_native.so"]

    wtop_hashes = []
    for name in ("wtop", "wtop-onefile"):
        candidate = arguments.bundle / name
        if candidate.is_file():
            digest = file_hash(candidate)
            if digest:
                wtop_hashes.append({"alg": "SHA-256", "content": digest})

    components = [
        component("wtop@%s" % revision or version, "wtop",
                  revision or version, "EUPL-1.2",
                  "WaterRun's top — a deep observability TUI",
                  hashes=wtop_hashes),
        component("lua@5.5.1", "lua", "5.5.1", "MIT",
                  "PUC Lua runtime bundled with the distribution"),
        component("luainstaller@1.3.0", "luainstaller", "1.3.0",
                  "LGPL-3.0-or-later",
                  "Build-time packaging tool; not present in the produced executables",
                  scope="excluded"),
    ]

    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:%s" % uuid.uuid5(
            uuid.NAMESPACE_URL, "wtop-sbom-%s" % (revision or version)),
        "version": 1,
        "metadata": {
            "component": {
                "bom-ref": "wtop@%s" % (revision or version),
                "type": "application",
                "name": "wtop",
                "version": revision or version,
                "licenses": [{"license": {"id": "EUPL-1.2"}}],
            },
        },
        "components": components,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print("wtop: SBOM written to %s (%s)" % (arguments.output, revision or "no revision"))


if __name__ == "__main__":
    main()
