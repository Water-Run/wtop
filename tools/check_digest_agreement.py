#!/usr/bin/env python3
"""Refuse when the SBOM and the integrity manifest disagree about a digest.

This project writes two documents that hash some of the same bytes:

  dist/SBOM.cyclonedx.json   `make sbom`      the component hashes
  dist/SHA256SUMS            `make checksums` every file the release ships

They are produced by different targets, from different tools, over different
lists, and nothing compared them.  A rebuild that refreshed one and not the
other would ship a release carrying two integrity records that contradict each
other, and every gate in this project would stay green: the SBOM's own test
checks its hashes against the files the generator was pointed at, the manifest's
test checks the manifest against itself, and neither asks what the other said
about the same bytes.

That is the same shape as a duplicated fact with nothing keeping the copies in
step, which this project has now found three times -- the ELF list written into
two CI steps, the collection limits written into `export.lua` and the agent
schema, and the release itself described by a chain of documents that nobody
owned end to end.

The check is deliberately the weaker, unambiguous direction: every SHA-256 the
SBOM records must appear in the manifest.  It does not require the manifest to
be a subset of the SBOM, because the manifest also covers the notices and the
build files the SBOM has no component for.  Nor does it require the SBOM to
record every shipped file: the SBOM describes components, and which files those
components stand for is stated in prose, not in a machine-readable field.

Written for Python 3.6 or later, like the other release tools in this
directory, because the oldest image this project measures on is manylinux2014
and its interpreter is 3.6.
"""

import argparse
import json
import sys


def read_manifest(path):
    """`sha256sum` output, as {path: digest}."""
    digests = {}
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                raise SystemExit(
                    "refusing to read %s: a line is not a digest and a path: %s"
                    % (path, line))
            digests[parts[1].strip()] = parts[0].strip()
    return digests


def read_sbom(path):
    """Every SHA-256 the document records, as a set of digests."""
    with open(path) as handle:
        document = json.load(handle)
    digests = set()
    for component in document.get("components", []):
        for entry in component.get("hashes") or []:
            algorithm = entry.get("alg")
            content = entry.get("content")
            if algorithm == "SHA-256" and content:
                digests.add(content)
    return digests


def main():
    parser = argparse.ArgumentParser(
        description="Refuse when the SBOM records a digest the manifest does not.")
    parser.add_argument("--sbom", required=True)
    parser.add_argument("--manifest", required=True)
    arguments = parser.parse_args()

    sbom = read_sbom(arguments.sbom)
    if not sbom:
        raise SystemExit(
            "refusing to agree with %s: it records no SHA-256 digest at all, so "
            "there is nothing to compare and a pass here would mean nothing"
            % arguments.sbom)
    manifest = read_manifest(arguments.manifest)
    if not manifest:
        raise SystemExit(
            "refusing to agree with %s: it lists no file, so it covers nothing"
            % arguments.manifest)

    missing = sorted(sbom - set(manifest.values()))
    if missing:
        sys.stderr.write(
            "wtop: the SBOM records %d SHA-256 digest(s); the manifest does "
            "not record %d of them.\n"
            "     These two documents describe the same release and "
            "contradict each other:\n"
            "       sbom     %s\n"
            "       manifest %s\n"
            "     A rebuild that refreshed one target and not the other is "
            "what produces this.\n"
            % (len(sbom), len(missing), arguments.sbom, arguments.manifest))
        for digest in missing:
            sys.stderr.write("       %s\n" % digest)
        return 1

    print("wtop: all %d SBOM digest(s) agree with %d manifest entries"
          % (len(sbom), len(manifest)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
