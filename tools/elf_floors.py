#!/usr/bin/env python3
"""Report the glibc symbol versions an ELF file needs, including any it carries.

Usage: tools/elf_floors.py [--quiet] <elf> [<elf> ...]

What a file requires is the highest glibc symbol version among the ELF images
that will actually execute on the target.  For an ordinary shared object or
executable that is just the file.  For a onefile bundle it is not: luainstaller
appends the native module and the PUC Lua interpreter to a launcher, and the
launcher extracts and runs them, so they are load-bearing on the target machine
even though no dynamic loader touches them until runtime.

That distinction is not academic.  Measuring only the outer file of the onefile
on this tree reports GLIBC_2.34, while the interpreter embedded at the end of
the same file requires GLIBC_2.38 -- so the artifact does not run on 2.34, and
the number a straightforward measurement produces is wrong in the direction that
hides a problem.  It is the same class of mistake as measuring only the native
module and calling it the bundle's floor, one level deeper and harder to see,
because here the unmeasured file is inside the measured one.

Each report line is:  offset  label  highest  all-versions
The file itself is always measured whole.  An embedded image is measured from
its own offset to the next ELF magic or end of file; the trailing bytes beyond
it do not affect the reading, because objdump resolves the dynamic table by
offset rather than by file size.

The one thing this cannot do is see inside a compressed payload, and the
onefile's payload is stored uncompressed -- two plain ELF images sit at a fixed
distance from the end.  If a future bundler compressed it, this scan would find
nothing and report the outer binary's floor again, which is the failure this
tool exists to prevent.  The count of embedded images is therefore always
printed, so "found none" is visible in a report rather than something a reader
has to notice.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

MAGIC = b"\x7fELF"
VERSION = re.compile(r"GLIBC_([0-9][0-9.]*)")


def version_key(text):
    return [int(field) for field in text.split(".")]


def required_versions(path):
    """The glibc versions objdump reports for the ELF image at offset 0."""
    try:
        # capture_output= and text= are 3.7 spellings.  The oldest image this
        # project measures on is manylinux2014, whose python is 3.6, and a tool
        # that cannot run there cannot be part of the evidence produced there:
        # the gate would report an artifact as unmeasurable and the run would
        # still exit successfully.  The long spellings say the same thing and
        # work on every Python 3.
        output = subprocess.run(
            ["objdump", "-T", path], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, universal_newlines=True, check=False,
        ).stdout
    except OSError as error:
        return None, str(error)
    return sorted({m for m in VERSION.findall(output)}, key=version_key), None


def inspect(path, workdir):
    """Measure one file.  Returns (highest, rows, problems)."""
    problems = []
    size = os.path.getsize(path)
    with open(path, "rb") as handle:
        data = handle.read()

    if data[:4] != MAGIC:
        return None, [], ["%s: not an ELF file" % path]

    rows = []
    highest = None

    outer, error = required_versions(path)
    if error:
        return None, [], ["%s: objdump failed: %s" % (path, error)]
    if not outer:
        # A file that links no versioned glibc symbol is not a lower
        # requirement; it is an unmeasurable one, and guessing would be worse.
        return None, [], ["%s: links no versioned glibc symbol, so no floor can "
                          "be claimed for it" % path]
    rows.append((0, "the file itself", outer))
    highest = outer[-1]

    scratch = os.path.join(workdir, "embedded.elf")
    offset = data.find(MAGIC, 1)
    while offset != -1:
        following = data.find(MAGIC, offset + 1)
        stop = following if following != -1 else size
        with open(path, "rb") as source:
            source.seek(offset)
            payload = source.read() if following == -1 else source.read(stop - offset)
        with open(scratch, "wb") as target:
            target.write(payload)
        versions, error = required_versions(scratch)
        if versions:
            rows.append((offset, "embedded ELF at +%d" % offset, versions))
            if version_key(versions[-1]) > version_key(highest):
                highest = versions[-1]
        elif error:
            # A byte sequence that looks like an ELF magic but is not one.  It
            # contributes nothing, and saying so beats silently skipping it.
            problems.append("%s: +%d looked like an ELF but objdump failed: %s"
                            % (path, offset, error))
        offset = following

    return highest, rows, problems


def render(path, highest, rows, problems):
    print("== %s" % path)
    for offset, label, versions in rows:
        marker = "0" if offset == 0 else "+%d" % offset
        print("  %-11s %-28s %-8s %s"
              % (marker, label, versions[-1], " ".join(versions)))
    embedded = len(rows) - 1 if rows else 0
    print("  embedded ELF images found: %d" % embedded)
    if highest:
        print("  highest required overall: %s" % highest)
    for problem in problems:
        print("  note: %s" % problem)
    print()


def main(argv):
    arguments = argv[1:]
    quiet = False
    if arguments and arguments[0] == "--quiet":
        quiet = True
        arguments = arguments[1:]
    if not arguments:
        print(__doc__, file=sys.stderr)
        return 2
    if quiet and len(arguments) != 1:
        # A single file is what makes the bare number unambiguous, so asking
        # for more than one is a mistake worth refusing rather than silently
        # answering with whichever came last.
        print("--quiet takes exactly one file", file=sys.stderr)
        return 2

    workdir = tempfile.mkdtemp(prefix="wtop-elf-floors.")
    try:
        status = 0
        for path in arguments:
            highest, rows, problems = inspect(path, workdir)
            if quiet:
                if highest:
                    print(highest)
                return 0 if highest else 1
            render(path, highest, rows, problems)
            if not highest:
                status = 1
        return status
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
